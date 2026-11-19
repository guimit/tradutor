import SwiftUI

@main
struct TradutorApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        // Estilo .menu: o conteúdo é convertido num NSMenu nativo,
        // e cada Picker aparece como submenu com visto na opção escolhida.
        MenuBarExtra {
            MenuContent(appState: appState, settings: appState.settings)
        } label: {
            Image(systemName: appState.isRunning ? "captions.bubble.fill" : "captions.bubble")
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(appState: appState, settings: appState.settings)
        }

        Window("Testar captação", id: WindowID.captureTest) {
            CaptureTestView()
        }
        .windowResizability(.contentSize)
        // Só abre a partir do menu, nunca no arranque.
        .defaultLaunchBehavior(.suppressed)

        Window("Testar transcrição", id: WindowID.transcriptionTest) {
            TranscriptionDebugView(settings: appState.settings, engines: appState.engines)
        }
        .defaultLaunchBehavior(.suppressed)
    }
}

enum WindowID {
    static let captureTest = "capture-test"
    static let transcriptionTest = "transcription-test"
}
