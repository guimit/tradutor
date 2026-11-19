import Foundation
import Observation

/// Lógica da janela de debug "Testar transcrição": liga uma fonte de áudio a um motor
/// e guarda os eventos para os mostrar.
@MainActor
@Observable
final class TranscriptionDebugModel {
    enum Phase: Equatable {
        case idle
        case downloading(progress: Double)
        case loading
        case running
        case permissionMissing
        case failed(String)
    }

    struct FinalLine: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let language: Language
        let start: TimeInterval
        let end: TimeInterval
    }

    private(set) var phase: Phase = .idle
    private(set) var finals: [FinalLine] = []
    private(set) var partial: (text: String, language: Language)?
    private(set) var metrics = TranscriptionMetrics.Snapshot()
    private(set) var sourceDescription = ""

    private var engine: (any TranscriptionEngine)?
    private var engineKey: String?
    private var source: (any AudioSource)?
    private var task: Task<Void, Never>?

    var isActive: Bool {
        switch phase {
        case .downloading, .loading, .running: true
        default: false
        }
    }

    /// Começa a transcrever o áudio do sistema ou, se `fileURL` for dado, esse ficheiro.
    func start(settings: AppSettings, fileURL: URL? = nil) async {
        guard !isActive else { return }

        do {
            let engine = try await preparedEngine(settings: settings)
            let source: any AudioSource = fileURL.map { FileAudioSource(url: $0) } ?? SystemAudioSource()
            sourceDescription = fileURL?.lastPathComponent ?? "Áudio do sistema"
            let audio = try await source.start()
            self.source = source

            engine.metrics.reset()
            phase = .running
            let events = engine.transcribe(audio)
            task = Task { [weak self] in
                for await event in events {
                    self?.handle(event, metrics: engine.metrics.snapshot)
                }
                self?.didFinish()
            }
        } catch AudioSourceError.permissionDenied {
            phase = .permissionMissing
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func stop() async {
        task?.cancel()
        task = nil
        await source?.stop()
        source = nil
        if isActive { phase = .idle }
    }

    func clear() {
        finals = []
        partial = nil
    }

    private func preparedEngine(settings: AppSettings) async throws -> any TranscriptionEngine {
        // Reutiliza o motor (e o modelo carregado) se a configuração não mudou.
        let key = "\(settings.transcriptionEngine)|\(settings.whisperModel)|\(settings.sourceLanguage.rawValue)|\(settings.portugueseVariant)"
        if let engine, engineKey == key { return engine }

        let engine = settings.makeTranscriptionEngine()
        phase = .downloading(progress: 0)
        try await engine.prepare { [weak self] progress in
            Task { @MainActor in
                guard let self else { return }
                self.phase = progress < 1 ? .downloading(progress: progress) : .loading
            }
        }
        self.engine = engine
        engineKey = key
        return engine
    }

    private func handle(_ event: TranscriptionEvent, metrics: TranscriptionMetrics.Snapshot) {
        self.metrics = metrics
        switch event {
        case .partial(let text, let language):
            partial = (text, language)
        case .final(let text, let language, let start, let end):
            finals.append(FinalLine(text: text, language: language, start: start, end: end))
            // O final substitui o parcial; o parcial seguinte trará só o que falta finalizar.
            partial = nil
        }
    }

    private func didFinish() {
        partial = nil
        if phase == .running { phase = .idle }
        switch (source as? SystemAudioSource)?.stopError {
        case AudioSourceError.permissionDenied?: phase = .permissionMissing
        case let error?: phase = .failed(error.localizedDescription)
        case nil: break
        }
        source = nil
    }
}
