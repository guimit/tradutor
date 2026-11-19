import SwiftUI

struct MenuContent: View {
    let appState: AppState
    @Bindable var settings: AppSettings
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button(appState.isRunning ? "Parar" : "Iniciar") {
            appState.toggleRunning()
        }
        .keyboardShortcut("s")

        statusItems

        Divider()

        Picker("Idioma de origem", selection: $settings.sourceLanguage) {
            ForEach(SourceLanguage.allCases, id: \.self) { source in
                Text(source.displayName).tag(source)
            }
        }

        Picker("Idioma de destino", selection: $settings.targetLanguage) {
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

        Button("Definições…") {
            openSettings()
            // App sem Dock (LSUIElement): sem isto, a janela abre atrás das outras apps.
            NSApplication.shared.activate()
        }
        .keyboardShortcut(",")

        Button("Testar captação…") {
            openWindow(id: WindowID.captureTest)
            NSApplication.shared.activate()
        }

        Button("Testar transcrição…") {
            openWindow(id: WindowID.transcriptionTest)
            NSApplication.shared.activate()
        }

        Divider()

        Button("Sair do Tradutor") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    @ViewBuilder
    private var statusItems: some View {
        switch appState.pipeline.status {
        case .idle:
            EmptyView()
        case .preparing(let progress):
            Text(progress.map { "A descarregar o modelo… \(Int($0 * 100)) %" } ?? "A carregar o modelo…")
        case .running:
            Text("A legendar o áudio do sistema")
            if let issue = appState.pipeline.translationIssue {
                Text(issue)
                Button("Abrir definições de tradução…") {
                    openSettings()
                    NSApplication.shared.activate()
                }
            }
        case .permissionMissing:
            Text("Falta a permissão de Gravação de Ecrã")
            Button("Abrir Definições do Sistema…") {
                ScreenCapturePermission.openSystemSettings()
            }
            // O macOS só aplica a permissão depois de a app reabrir.
            Button("Reabrir o Tradutor") {
                AppRelauncher.relaunch()
            }
        case .failed(let message):
            Text("Erro: \(message)")
        }
    }
}
