import AVFAudio
import CoreMedia
import Foundation
import Speech
import Synchronization

/// Motor com o SpeechAnalyzer/SpeechTranscriber da Apple (macOS 26+, on-device).
///
/// Diferenças em relação ao WhisperKit:
/// - Não deteta o idioma: precisa de um idioma de origem fixo.
/// - Suporta pt-PT e pt-BR como locales distintos (não depende de prompt).
/// - Os modelos são geridos pelo sistema (AssetInventory), partilhados com outras apps.
@MainActor
final class AppleSpeechEngine: TranscriptionEngine {
    enum EngineError: LocalizedError {
        case automaticLanguageUnsupported
        case localeUnsupported(String)
        case noCompatibleAudioFormat

        var errorDescription: String? {
            switch self {
            case .automaticLanguageUnsupported:
                "O motor da Apple não deteta o idioma automaticamente. Escolhe um idioma de origem fixo ou usa o WhisperKit."
            case .localeUnsupported(let identifier):
                "O motor da Apple não suporta \(identifier) neste Mac."
            case .noCompatibleAudioFormat:
                "Não foi possível obter um formato de áudio compatível com o SpeechAnalyzer."
            }
        }
    }

    let configuration: TranscriptionConfiguration
    let metrics = TranscriptionMetrics()

    private var transcriber: SpeechTranscriber?
    private var language: Language?

    init(configuration: TranscriptionConfiguration) {
        self.configuration = configuration
    }

    static func locale(for language: Language, variant: PortugueseVariant) -> Locale {
        switch language {
        case .portuguese: Locale(identifier: variant.rawValue)
        case .english: Locale(identifier: "en-US")
        case .spanish: Locale(identifier: "es-ES")
        }
    }

    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        guard transcriber == nil else { return }
        guard case .fixed(let language) = configuration.sourceLanguage else {
            throw EngineError.automaticLanguageUnsupported
        }

        let requested = Self.locale(for: language, variant: configuration.portugueseVariant)
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
            throw EngineError.localeUnsupported(requested.identifier(.bcp47))
        }

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            // Resultados voláteis = parciais; sem eles só teríamos finais.
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )

        // Descarrega o modelo do idioma se ainda não estiver instalado.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            let observation = request.progress.observe(\.fractionCompleted) { progressObject, _ in
                progress(progressObject.fractionCompleted)
            }
            defer { observation.invalidate() }
            do {
                try await request.downloadAndInstall()
            } catch {
                throw ModelDownloadError(modelName: "da Apple para \(locale.identifier(.bcp47))", underlying: error)
            }
        }
        progress(1)

        self.transcriber = transcriber
        self.language = language
    }

    func transcribe(_ audio: AsyncStream<AudioChunk>) -> AsyncStream<TranscriptionEvent> {
        guard let transcriber, let language else {
            assertionFailure("prepare() tem de ser chamado antes de transcribe()")
            return AsyncStream { $0.finish() }
        }
        let metrics = metrics
        let (events, continuation) = AsyncStream.makeStream(of: TranscriptionEvent.self)

        let task = Task.detached(priority: .userInitiated) {
            do {
                try await Self.run(transcriber: transcriber, language: language, audio: audio, metrics: metrics, continuation: continuation)
            } catch {
                // Erros a meio (ex.: cancelamento) terminam simplesmente o stream.
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return events
    }

    private nonisolated static func run(
        transcriber: SpeechTranscriber,
        language: Language,
        audio: AsyncStream<AudioChunk>,
        metrics: TranscriptionMetrics,
        continuation: AsyncStream<TranscriptionEvent>.Continuation
    ) async throws {
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber],
            considering: AudioFormatConverter.outputFormat
        ) else { throw EngineError.noCompatibleAudioFormat }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.prepareToAnalyze(in: analyzerFormat)
        let (inputs, inputContinuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        try await analyzer.start(inputSequence: inputs)

        // Para medir a latência: quando (relógio real) foi entregue o áudio até cada instante.
        let feedLog = FeedLog()

        // Lê os resultados em paralelo com o envio de áudio.
        let resultsTask = Task {
            var deduplicator = FinalDeduplicator()
            for try await result in transcriber.results {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let end = result.range.end.seconds
                if let delay = feedLog.delay(sinceAudioReached: end) {
                    metrics.recordEventDelay(delay)
                }
                if result.isFinal {
                    let start = result.range.start.seconds
                    if let text = deduplicator.accept(text: text, start: start, end: end) {
                        continuation.yield(.final(text: text, language: language, start: start, end: end))
                    }
                } else {
                    continuation.yield(.partial(text: text, language: language))
                }
            }
        }

        let converter = InputConverter(outputFormat: analyzerFormat)
        for await chunk in audio {
            guard let buffer = converter.convert(chunk.samples) else { continue }
            // Passar o tempo de início alinha `result.range` com `AudioChunk.timestamp`.
            let startTime = CMTime(seconds: chunk.timestamp, preferredTimescale: 16_000)
            inputContinuation.yield(AnalyzerInput(buffer: buffer, bufferStartTime: startTime))
            feedLog.record(audioEnd: chunk.timestamp + chunk.duration)
        }
        inputContinuation.finish()

        if Task.isCancelled {
            await analyzer.cancelAndFinishNow()
        } else {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        try await resultsTask.value
    }
}

/// Registo de "áudio até t entregue no instante x", para calcular a latência dos resultados.
private final class FeedLog: Sendable {
    private let entries = Mutex<[(audioEnd: TimeInterval, time: ContinuousClock.Instant)]>([])

    func record(audioEnd: TimeInterval) {
        entries.withLock {
            $0.append((audioEnd, .now))
            if $0.count > 1_000 { $0.removeFirst($0.count - 1_000) }
        }
    }

    /// Tempo decorrido desde que o áudio até `audioTime` foi entregue.
    func delay(sinceAudioReached audioTime: TimeInterval) -> TimeInterval? {
        entries.withLock { entries in
            guard let entry = entries.first(where: { $0.audioEnd >= audioTime - 0.01 }) else { return nil }
            let elapsed = entry.time.duration(to: .now)
            return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
        }
    }
}

/// Converte as amostras float32/16 kHz/mono para o formato pedido pelo SpeechAnalyzer.
/// Usado só pela tarefa de transcrição.
private final class InputConverter {
    private let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter?

    init(outputFormat: AVAudioFormat) {
        self.outputFormat = outputFormat
        let inputFormat = AudioFormatConverter.outputFormat
        converter = inputFormat == outputFormat ? nil : AVAudioConverter(from: inputFormat, to: outputFormat)
    }

    func convert(_ samples: [Float]) -> AVAudioPCMBuffer? {
        let inputFormat = AudioFormatConverter.outputFormat
        guard !samples.isEmpty,
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(samples.count))
        else { return nil }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer {
            input.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count)
        }
        guard let converter else { return input }

        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(samples.count) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }
        var delivered = false
        let status = converter.convert(to: output, error: nil) { _, inputStatus in
            if delivered {
                inputStatus.pointee = .noDataNow
                return nil
            }
            delivered = true
            inputStatus.pointee = .haveData
            return input
        }
        return status == .error || output.frameLength == 0 ? nil : output
    }
}
