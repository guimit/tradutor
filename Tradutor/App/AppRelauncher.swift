import AppKit

enum AppRelauncher {
    /// Fecha e volta a abrir a app (necessário para o macOS aplicar a permissão de Gravação de Ecrã).
    @MainActor
    static func relaunch() {
        // Um processo auxiliar espera que esta instância termine antes de a reabrir;
        // se abríssemos já, o `open` limitar-se-ia a ativar a instância atual.
        let bundlePath = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; open \"$0\"", bundlePath]
        try? process.run()
        NSApplication.shared.terminate(nil)
    }
}
