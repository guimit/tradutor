import Foundation
import Observation

/// Estado global da app: as definições, o pipeline das legendas e o overlay.
@MainActor
@Observable
final class AppState {
    let settings: AppSettings
    let engines = TranscriptionEngineProvider()
    let pipeline: CaptionPipeline
    @ObservationIgnored private(set) var overlay: OverlayController!
    @ObservationIgnored private var settingsObserver: Task<Void, Never>?
    @ObservationIgnored private var targetObserver: Task<Void, Never>?

    init(settings: AppSettings = AppSettings()) {
        self.settings = settings
        pipeline = CaptionPipeline(store: CaptionStore(), engines: engines, makeSource: Self.makeAudioSource)
        overlay = OverlayController(settings: settings, pipeline: pipeline)

        // Mudar o motor, o modelo, o idioma de origem, a variante ou o motor de tradução
        // (ex.: no menu) a meio obriga a recriar os motores: reinicia-se o pipeline.
        // O motor de transcrição fica em cache, por isso o reinício é rápido.
        settingsObserver = Task { [weak self, settings] in
            var previous: String?
            for await key in Observations({ "\(settings.transcriptionEngineKey)|\(settings.translationEngine.rawValue)" }) {
                defer { previous = key }
                guard let self, previous != nil, previous != key, self.pipeline.isActive else { continue }
                await self.pipeline.stop()
                await self.pipeline.start(settings: settings)
            }
        }
        // O idioma de destino muda-se sem reiniciar: só se retraduz.
        targetObserver = Task { [weak self, settings] in
            var previous: Language?
            for await target in Observations({ settings.targetLanguage }) {
                defer { previous = target }
                guard let self, previous != nil, previous != target else { continue }
                self.pipeline.targetLanguageChanged(settings: settings)
            }
        }

        #if DEBUG
        // Para testes automáticos: `open Tradutor.app --args -TradutorAutoStart YES`
        // (ou `-TradutorEditOverlay YES` para abrir já no modo de ajuste da posição).
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "TradutorAutoStart") { toggleRunning() }
        if defaults.bool(forKey: "TradutorEditOverlay") {
            Task { [overlay] in overlay?.setEditing(true) }
        }
        #endif
    }

    private static func makeAudioSource() -> any AudioSource {
        #if DEBUG
        // Para testes sem permissão de captação: `--args -TradutorAudioFile /caminho/fala.wav`.
        if let path = UserDefaults.standard.string(forKey: "TradutorAudioFile") {
            return FileAudioSource(url: URL(fileURLWithPath: path))
        }
        #endif
        return SystemAudioSource()
    }

    var isRunning: Bool { pipeline.isActive }

    func toggleRunning() {
        Task {
            if pipeline.isActive {
                await pipeline.stop()
            } else {
                await pipeline.start(settings: settings)
            }
        }
    }
}
