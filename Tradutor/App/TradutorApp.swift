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
            MenuBarLabel(appState: appState)
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

/// Ícone da barra de menus: muda com o estado e, a ouvir, mostra o idioma detetado.
private struct MenuBarLabel: View {
    let appState: AppState

    var body: some View {
        let state = appState.menuBarState
        HStack(spacing: 3) {
            Image(systemName: symbol(for: state))
            if state != .stopped, state != .preparing, let language = appState.pipeline.detectedLanguage {
                Text(language.rawValue.uppercased())
            }
        }
        .accessibilityLabel(accessibilityLabel(for: state))
    }

    private func symbol(for state: AppState.MenuBarState) -> String {
        switch state {
        case .stopped: "captions.bubble"
        case .preparing: "ellipsis.bubble"
        case .listening: "captions.bubble.fill"
        case .translating: "translate"
        case .problem: "exclamationmark.bubble"
        }
    }

    private func accessibilityLabel(for state: AppState.MenuBarState) -> String {
        switch state {
        case .stopped: "Tradutor: parado"
        case .preparing: "Tradutor: a preparar"
        case .listening: "Tradutor: a ouvir"
        case .translating: "Tradutor: a traduzir"
        case .problem: "Tradutor: há um problema"
        }
    }
}

enum WindowID {
    static let captureTest = "capture-test"
    static let transcriptionTest = "transcription-test"
}
