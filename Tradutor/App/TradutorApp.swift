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
    }
}
