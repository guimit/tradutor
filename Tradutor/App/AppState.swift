import AppKit
import Observation

/// Estado global da app: as definições, o pipeline das legendas e o overlay.
@MainActor
@Observable
final class AppState {
    let settings: AppSettings
    let engines = TranscriptionEngineProvider()
    let pipeline: CaptionPipeline
    @ObservationIgnored private(set) var overlay: OverlayController!
    @ObservationIgnored private(set) var hotKeys: GlobalHotKeys!
    @ObservationIgnored private var hotKeyObserver: Task<Void, Never>?
    @ObservationIgnored private var systemObservers: [Task<Void, Never>] = []
    /// As legendas foram paradas por o Mac (ou o ecrã) ir dormir: retomam ao acordar.
    @ObservationIgnored private var pausedForSleep = false

    /// Retomar as legendas no próximo arranque: a permissão caiu a meio, e o macOS só a aplica
    /// depois de a app reabrir (pelo nosso botão ou pelo "Sair e reabrir" das Definições do Sistema).
    private static let resumeAfterRelaunchKey = "resumeCaptionsAfterRelaunch"
    @ObservationIgnored private var settingsObserver: Task<Void, Never>?
    @ObservationIgnored private var targetObserver: Task<Void, Never>?

    init(settings: AppSettings = AppSettings()) {
        self.settings = settings
        pipeline = CaptionPipeline(store: CaptionStore(), engines: engines, makeSource: Self.makeAudioSource)
        overlay = OverlayController(settings: settings, pipeline: pipeline)
        hotKeys = GlobalHotKeys { [weak self] action in self?.perform(action) }

        hotKeyObserver = Task { [weak self, settings] in
            for await (toggle, cycle) in Observations({ (settings.toggleCaptionsHotKey, settings.cycleDisplayModeHotKey) }) {
                self?.hotKeys.set(toggle, for: .toggleCaptions)
                self?.hotKeys.set(cycle, for: .cycleDisplayMode)
            }
        }

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

        observeSystem()
        if UserDefaults.standard.bool(forKey: Self.resumeAfterRelaunchKey) {
            UserDefaults.standard.removeObject(forKey: Self.resumeAfterRelaunchKey)
            // `isGranted` é calculado no arranque do processo, por isso aqui está certo.
            if ScreenCapturePermission.isGranted { toggleRunning() }
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
            // `-TradutorAudioFileLoop YES` repete o ficheiro sem fim (medições de desempenho).
            return FileAudioSource(
                url: URL(fileURLWithPath: path),
                loops: UserDefaults.standard.bool(forKey: "TradutorAudioFileLoop")
            )
        }
        #endif
        return SystemAudioSource()
    }

    var isRunning: Bool { pipeline.isActive }

    // MARK: - Sistema

    private func observeSystem() {
        // Dispositivo de saída mudou: recomeça só a captação (o motor e as legendas continuam).
        systemObservers.append(Task { [weak self] in
            for await _ in AudioDeviceMonitor.defaultOutputChanges() {
                await self?.pipeline.restartAudio()
            }
        })

        // Sono do Mac ou dos ecrãs: com os ecrãs desligados não há legendas para ver, e a
        // captação do ScreenCaptureKit (que depende de um ecrã) não sobrevive bem ao sono.
        let center = NSWorkspace.shared.notificationCenter
        let sleeps = [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification]
        let wakes = [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification]
        for name in sleeps {
            systemObservers.append(Task { [weak self] in
                for await _ in center.notifications(named: name).map({ _ in () }) {
                    await self?.pauseForSleep()
                }
            })
        }
        for name in wakes {
            systemObservers.append(Task { [weak self] in
                for await _ in center.notifications(named: name).map({ _ in () }) {
                    await self?.resumeAfterSleep()
                }
            })
        }

        // A permissão caiu a meio: retoma-se sozinho depois de a app reabrir.
        systemObservers.append(Task { [weak self, pipeline] in
            var previous = pipeline.status
            for await status in Observations({ pipeline.status }) {
                defer { previous = status }
                guard self != nil, status == .permissionMissing, previous == .running else { continue }
                UserDefaults.standard.set(true, forKey: Self.resumeAfterRelaunchKey)
            }
        })
    }

    private func pauseForSleep() async {
        guard pipeline.isActive else { return }
        pausedForSleep = true
        await pipeline.stop()
    }

    private func resumeAfterSleep() async {
        guard pausedForSleep else { return }
        pausedForSleep = false
        // Dá tempo ao áudio e aos ecrãs para acordarem antes de pedir a captação.
        try? await Task.sleep(for: .seconds(2))
        guard !pipeline.isActive else { return }
        await pipeline.start(settings: settings)
    }

    private func perform(_ action: GlobalHotKeys.Action) {
        switch action {
        case .toggleCaptions:
            toggleRunning()
        case .cycleDisplayMode:
            cycleDisplayMode()
        }
    }

    func cycleDisplayMode() {
        settings.overlayDisplayMode = settings.overlayDisplayMode.next
        overlay.showNotice(settings.isTranslationNeeded
            ? settings.overlayDisplayMode.displayName
            : "\(settings.overlayDisplayMode.displayName) (sem tradução: origem = destino)")
    }

    /// O que o ícone da barra de menus mostra.
    enum MenuBarState: Equatable {
        case stopped
        case preparing
        case listening
        case translating
        /// Algo impede ou estraga as legendas (permissão, erro, idiomas em falta, silêncio).
        case problem
    }

    var menuBarState: MenuBarState {
        switch pipeline.status {
        case .idle: return .stopped
        case .preparing: return .preparing
        case .permissionMissing, .failed: return .problem
        case .running:
            if pipeline.translationIssue != nil || pipeline.silentFor != nil { return .problem }
            if let language = pipeline.detectedLanguage, language != settings.targetLanguage { return .translating }
            return .listening
        }
    }

    func toggleRunning() {
        pausedForSleep = false
        UserDefaults.standard.removeObject(forKey: Self.resumeAfterRelaunchKey)
        Task {
            if pipeline.isActive {
                await pipeline.stop()
            } else {
                await pipeline.start(settings: settings)
            }
        }
    }
}
