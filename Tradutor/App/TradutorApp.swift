import SwiftUI

@main
struct TradutorApp: App {
    @State private var appState = AppState()
    @State private var settings = AppSettings()

    var body: some Scene {
        // Estilo .menu: o conteúdo é convertido num NSMenu nativo,
        // e cada Picker aparece como submenu com visto na opção escolhida.
        MenuBarExtra {
            MenuContent(appState: appState, settings: settings)
        } label: {
            Image(systemName: appState.isRunning ? "captions.bubble.fill" : "captions.bubble")
        }
        .menuBarExtraStyle(.menu)

        Window("Testar captação", id: WindowID.captureTest) {
            CaptureTestView()
        }
        .windowResizability(.contentSize)
        // Só abre a partir do menu, nunca no arranque.
        .defaultLaunchBehavior(.suppressed)

        Window("Testar transcrição", id: WindowID.transcriptionTest) {
            TranscriptionDebugView(settings: settings)
        }
        .defaultLaunchBehavior(.suppressed)
    }
}

enum WindowID {
    static let captureTest = "capture-test"
    static let transcriptionTest = "transcription-test"
}
