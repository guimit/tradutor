import SwiftUI

struct MenuContent: View {
    let appState: AppState
    @Bindable var settings: AppSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(appState.isRunning ? "Parar" : "Iniciar") {
            appState.toggleRunning()
        }
        .keyboardShortcut("s")

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

        Divider()

        Button("Testar captação…") {
            openWindow(id: WindowID.captureTest)
            // App sem Dock (LSUIElement): sem isto, a janela abre atrás das outras apps.
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
}
