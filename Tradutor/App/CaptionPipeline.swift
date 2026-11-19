import Foundation
import Observation
import Synchronization

/// Liga as peças: `AudioSource` → `TranscriptionEngine` → `CaptionStore` ← `CaptionTranslator`.
/// O overlay mostra o `CaptionStore`.
@MainActor
@Observable
final class CaptionPipeline {
    enum Status: Equatable, Sendable {
        case idle
        /// A preparar o motor; `downloadProgress` é `nil` quando já está a carregar o modelo.
        case preparing(downloadProgress: Double?)
        case running
        case permissionMissing
        case failed(String)
    }

    private(set) var status: Status = .idle
    /// Problema de tradução que não impede as legendas (ex.: idiomas por descarregar).
    private(set) var translationIssue: String?
    private(set) var latency = CaptionLatency()
    /// Idioma da última fala transcrita (o detetado, com origem Auto).
    private(set) var detectedLanguage: Language?
    /// Segundos sem som no áudio do sistema, a partir de `silenceWarningDelay`; `nil` se houver som.
    private(set) var silentFor: Int?
    let store: CaptionStore

    @ObservationIgnored private let engines: TranscriptionEngineProvider
    @ObservationIgnored private let makeSource: @MainActor () -> any AudioSource
    @ObservationIgnored private var source: (any AudioSource)?
    @ObservationIgnored private var translator: CaptionTranslator?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var holdsEngine = false
    /// Identifica a sessão atual, para uma tarefa antiga não mexer numa sessão nova.
    @ObservationIgnored private var runID = UUID()
    @ObservationIgnored private var audioClock = AudioClock()
    @ObservationIgnored private var silenceTask: Task<Void, Never>?
    /// Segmentos confirmados à espera da tradução final: (fim da fala, hora do original).
    @ObservationIgnored private var pendingLatency: [CaptionSegment.ID: (speechEnd: Date, original: Date)] = [:]

    init(
        store: CaptionStore,
        engines: TranscriptionEngineProvider,
        makeSource: @escaping @MainActor () -> any AudioSource = { SystemAudioSource() }
    ) {
        self.store = store
        self.engines = engines
        self.makeSource = makeSource
    }

    var isActive: Bool {
        switch status {
        case .preparing, .running: true
        default: false
        }
    }

    func start(settings: AppSettings) async {
        guard !isActive else { return }
        status = .preparing(downloadProgress: nil)
        translationIssue = nil
        latency = CaptionLatency()
        detectedLanguage = settings.sourceLanguage.fixedLanguage
        silentFor = nil
        store.clear()

        do {
            let engine = try await engines.acquire(settings: settings) { [weak self] progress in
                guard let self, case .preparing = self.status else { return }
                self.status = .preparing(downloadProgress: progress < 1 ? progress : nil)
            }
            holdsEngine = true
            // O utilizador pode ter carregado em Parar enquanto o modelo carregava.
            guard isActive else { return releaseEngine() }

            let source = makeSource()
            let audio = try await source.start()
            self.source = source
            guard isActive else { return await stop() }

            translator = makeTranslator(settings: settings)
            checkTranslationPairs(settings: settings)

            engine.metrics.reset()
            status = .running
            audioClock = AudioClock()
            let events = engine.transcribe(Self.relay(audio, clock: audioClock))
            let runID = UUID()
            self.runID = runID
            task = Task { [weak self] in
                for await event in events {
                    guard let self else { return }
                    self.handle(event, targetLanguage: settings.targetLanguage)
                }
                await self?.didFinish(runID: runID)
            }
            watchSilence(settings: settings)
        } catch AudioSourceError.permissionDenied {
            releaseEngine()
            status = .permissionMissing
        } catch {
            releaseEngine()
            status = .failed(error.localizedDescription)
        }
    }

    func stop() async {
        task?.cancel()
        task = nil
        silenceTask?.cancel()
        silenceTask = nil
        silentFor = nil
        detectedLanguage = nil
        translator?.cancelAll()
        translator = nil
        await source?.stop()
        source = nil
        releaseEngine()
        store.clear()
        pendingLatency.removeAll()
        status = .idle
    }

    /// Limpa as legendas (ex.: depois de um silêncio) e cancela as traduções pendentes.
    func clearCaptions() {
        store.clear()
        translator?.update()
    }

    /// Mudou o idioma de destino: retraduz o que está no ecrã e verifica os idiomas.
    func targetLanguageChanged(settings: AppSettings) {
        guard let translator else { return }
        translator.cancelAll()
        pendingLatency.removeAll()
        store.retarget(to: settings.targetLanguage)
        translator.update()
        checkTranslationPairs(settings: settings)
    }

    // MARK: - Eventos

    private func handle(_ event: TranscriptionEvent, targetLanguage: Language) {
        switch event {
        case .partial(_, let language), .final(_, let language, _, _): detectedLanguage = language
        }
        store.apply(event, targetLanguage: targetLanguage)
        if case .final(_, _, _, let end) = event,
           let segment = store.segments.last, segment.isConfirmed {
            let now = Date.now
            let speechEnd = audioClock.wallTime(forStreamTime: end) ?? now
            latency.speechToOriginal.record(now.timeIntervalSince(speechEnd))
            if segment.needsTranslation { pendingLatency[segment.id] = (speechEnd, now) }
        }
        translator?.update()
    }

    private func makeTranslator(settings: AppSettings) -> CaptionTranslator {
        let translator = CaptionTranslator(
            store: store,
            engine: settings.makeTranslationEngine(),
            portugueseVariant: settings.portugueseVariant
        )
        translator.onDelivery = { [weak self] delivery in
            guard let self, delivery.isFinal else { return }
            let now = Date.now
            // Uma frase partida em vários finais conta a latência de cada um.
            for id in delivery.segmentIDs {
                guard let pending = self.pendingLatency.removeValue(forKey: id) else { continue }
                self.latency.originalToTranslation.record(now.timeIntervalSince(pending.original))
                self.latency.speechToTranslation.record(now.timeIntervalSince(pending.speechEnd))
            }
            self.translationIssue = nil
        }
        translator.onError = { [weak self] error in
            self?.translationIssue = error.localizedDescription
        }
        return translator
    }

    /// Avisa logo no início se faltarem idiomas, em vez de esperar pela primeira frase.
    private func checkTranslationPairs(settings: AppSettings) {
        guard settings.isTranslationNeeded else { return }
        let engine = settings.makeTranslationEngine()
        let variant = settings.portugueseVariant
        let target = TranslationLanguage(language: settings.targetLanguage, portugueseVariant: variant)
        let sources: [Language] = switch settings.sourceLanguage {
        case .auto: Language.allCases.filter { $0 != settings.targetLanguage }
        case .fixed(let language): [language]
        }
        Task { [weak self] in
            var missing: [String] = []
            for language in sources {
                let source = TranslationLanguage(language: language, portugueseVariant: variant)
                if await engine.status(from: source, to: target) != .ready {
                    missing.append("\(source.displayName) → \(target.displayName)")
                }
            }
            guard let self, !missing.isEmpty else { return }
            self.translationIssue = "Faltam idiomas de tradução (\(missing.joined(separator: ", "))). "
                + "Descarrega-os em Definições › Tradução."
        }
    }

    /// Avisa quando o áudio do sistema fica em silêncio (nada a tocar, volume da app a zero,
    /// som a sair por um dispositivo que não é captado…). Verifica-se uma vez por segundo.
    private func watchSilence(settings: AppSettings) {
        silenceTask?.cancel()
        let clock = audioClock
        silenceTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                let silence = Date.now.timeIntervalSince(clock.lastSound)
                let value = silence >= settings.silenceWarningDelay ? Int(silence) : nil
                if value != self.silentFor { self.silentFor = value }
            }
        }
    }

    /// O stream de eventos acabou sem `stop()`: a captação parou sozinha (ex.: permissão retirada).
    private func didFinish(runID: UUID) async {
        guard runID == self.runID, task != nil else { return }
        task = nil
        let error = (source as? SystemAudioSource)?.stopError
        await stop()
        switch error {
        case AudioSourceError.permissionDenied?: status = .permissionMissing
        case let error?: status = .failed(error.localizedDescription)
        case nil: break
        }
    }

    private func releaseEngine() {
        guard holdsEngine else { return }
        holdsEngine = false
        engines.release()
    }

    /// Passa o áudio adiante, registando a relação entre o tempo do stream e o relógio real.
    private nonisolated static func relay(_ audio: AsyncStream<AudioChunk>, clock: AudioClock) -> AsyncStream<AudioChunk> {
        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self, bufferingPolicy: .bufferingNewest(500))
        let task = Task.detached {
            for await chunk in audio {
                clock.observe(chunk)
                continuation.yield(chunk)
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
}

/// Converte tempos do stream de áudio (`AudioChunk.timestamp`, em segundos desde o início da
/// captação) em horas reais, para medir a latência desde que a fala acontece.
final class AudioClock: Sendable {
    /// Menor diferença observada entre a chegada de um chunk e o fim do áudio que contém:
    /// a chegada mais "pontual" é a melhor estimativa (as outras incluem atrasos de entrega).
    private let offset = Mutex<TimeInterval?>(nil)
    private let lastSoundTime = Mutex(Date.now)

    /// Abaixo disto o chunk conta como silêncio (ruído de fundo digital, não fala nem música).
    static let silenceThreshold: Float = -60

    /// Última vez que chegou áudio com som (ou o início da captação). O ScreenCaptureKit
    /// pode deixar de entregar chunks quando nada toca, por isso conta o tempo e não os chunks.
    var lastSound: Date { lastSoundTime.withLock { $0 } }

    func observe(_ chunk: AudioChunk) {
        let now = Date.now
        let candidate = now.timeIntervalSinceReferenceDate - (chunk.timestamp + chunk.duration)
        offset.withLock { $0 = min($0 ?? candidate, candidate) }
        if chunk.rmsDecibels > Self.silenceThreshold { lastSoundTime.withLock { $0 = now } }
    }

    func wallTime(forStreamTime time: TimeInterval) -> Date? {
        offset.withLock { $0 }.map { Date(timeIntervalSinceReferenceDate: time + $0) }
    }
}

/// Latências medidas (segundos), para o modo debug.
struct CaptionLatency: Equatable, Sendable {
    struct Stat: Equatable, Sendable {
        private(set) var last: TimeInterval?
        private(set) var total: TimeInterval = 0
        private(set) var count = 0

        var average: TimeInterval? { count > 0 ? total / Double(count) : nil }

        mutating func record(_ value: TimeInterval) {
            last = value
            total += value
            count += 1
        }
    }

    /// Do fim da fala até o original confirmado aparecer.
    var speechToOriginal = Stat()
    /// Do original confirmado até à sua tradução final.
    var originalToTranslation = Stat()
    /// Do fim da fala até à tradução final.
    var speechToTranslation = Stat()
}
