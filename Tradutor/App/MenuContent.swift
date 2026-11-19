import SwiftUI

struct MenuContent: View {
    let appState: AppState
    @Bindable var settings: AppSettings
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        statusItems

        Button(appState.isRunning ? "Parar legendas" : "Iniciar legendas") {
            appState.toggleRunning()
        }
        .keyboardShortcut("s")

        Divider()

        Picker("Idioma de origem", selection: $settings.sourceLanguage) {
            ForEach(SourceLanguage.allCases, id: \.self) { source in
                Text(source.displayName).tag(source)
            }
        }

        Picker("Traduzir para", selection: $settings.targetLanguage) {
            ForEach(Language.allCases) { language in
                Text(language.displayName).tag(language)
            }
        }

        Picker("Mostrar", selection: $settings.overlayDisplayMode) {
            ForEach(OverlayDisplayMode.allCases) { Text($0.displayName).tag($0) }
        }

        Toggle("Ajustar posição das legendas", isOn: Binding(
            get: { appState.overlay.model.isEditing },
            set: { appState.overlay.setEditing($0) }
        ))

        Divider()

        Button("Definições…") { open(.general) }
            .keyboardShortcut(",")

        Button("Sair do Tradutor") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    /// Estado atual e, quando há um problema, o que fazer.
    @ViewBuilder
    private var statusItems: some View {
        let pipeline = appState.pipeline
        switch pipeline.status {
        case .idle:
            Text(idleDescription)
            if settings.transcriptionEngine == .appleSpeech, settings.sourceLanguage == .auto {
                Text("⚠︎ O motor da Apple precisa de um idioma de origem fixo")
            } else if settings.transcriptionEngine == .whisperKit, !WhisperModelStore.isDownloaded(settings.whisperModel) {
                Text("Modelo \(settings.whisperModel.shortName) por descarregar (\(settings.whisperModel.approximateSize)): descarrega ao iniciar")
            }

        case .preparing(let progress):
            Text(progress.map { "A descarregar o modelo… \(Int($0 * 100)) %" } ?? "A carregar o modelo…")

        case .running:
            Text(runningDescription)
            if let seconds = pipeline.silentFor {
                Text("⚠︎ Sem áudio há \(seconds) s: confirma que está a tocar som no Mac")
            }
            if let issue = pipeline.translationIssue {
                Text("⚠︎ \(issue)")
                Button("Descarregar idiomas de tradução…") { open(.engine) }
            }

        case .permissionMissing:
            Text("⚠︎ Falta a permissão de Gravação de Ecrã e Áudio do Sistema")
            Button("Abrir Definições do Sistema…") {
                ScreenCapturePermission.openSystemSettings()
            }
            // O macOS só aplica a permissão depois de a app reabrir.
            Button("Reabrir o Tradutor") {
                AppRelauncher.relaunch()
            }

        case .failed(let message):
            Text("⚠︎ \(message)")
            Button("Tentar de novo") { appState.toggleRunning() }
            Button("Abrir definições do motor…") { open(.engine) }
        }

        Divider()
    }

    private var idleDescription: String {
        if let hotKey = settings.toggleCaptionsHotKey {
            return "Legendas desligadas (\(hotKey.displayString) para ligar)"
        }
        return "Legendas desligadas"
    }

    private var runningDescription: String {
        guard let language = appState.pipeline.detectedLanguage else { return "A ouvir…" }
        if language == settings.targetLanguage {
            return "A ouvir · \(language.displayName)"
        }
        return "A traduzir · \(language.displayName) → \(settings.targetLanguage.displayName)"
    }

    private func open(_ tab: SettingsTab) {
        SettingsTab.select(tab)
        openSettings()
        // App sem Dock (LSUIElement): sem isto, a janela abre atrás das outras apps.
        NSApplication.shared.activate()
    }
}
