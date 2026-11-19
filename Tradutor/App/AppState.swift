import Observation

/// Estado de execução da app. Por agora só guarda se as legendas estão ativas;
/// o pipeline (áudio → transcrição → tradução → overlay) será ligado aqui.
@MainActor
@Observable
final class AppState {
    private(set) var isRunning = false

    func toggleRunning() {
        isRunning.toggle()
    }
}
