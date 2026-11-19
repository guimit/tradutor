import Foundation
import Observation

/// Liga as peças: `AudioSource` → `TranscriptionEngine` → `CaptionStore` (que o overlay mostra).
/// A tradução entra aqui na próxima fase, entre os finais e o `CaptionStore`.
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
    let store: CaptionStore

    /// Por agora não há motor de tradução: o overlay mostra sempre o original.
    var isTranslationAvailable: Bool { false }

    @ObservationIgnored private let engines: TranscriptionEngineProvider
    @ObservationIgnored private let makeSource: @MainActor () -> any AudioSource
    @ObservationIgnored private var source: (any AudioSource)?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var holdsEngine = false
    /// Identifica a sessão atual, para uma tarefa antiga não mexer numa sessão nova.
    @ObservationIgnored private var runID = UUID()

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

            engine.metrics.reset()
            status = .running
            let events = engine.transcribe(audio)
            let runID = UUID()
            self.runID = runID
            task = Task { [weak self] in
                for await event in events {
                    guard let self else { return }
                    self.store.apply(event, targetLanguage: settings.targetLanguage)
                }
                await self?.didFinish(runID: runID)
            }
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
        await source?.stop()
        source = nil
        releaseEngine()
        store.clear()
        status = .idle
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
}
