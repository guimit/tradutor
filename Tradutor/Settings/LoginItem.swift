import ServiceManagement
import SwiftUI

/// "Iniciar no login" com `SMAppService.mainApp` (macOS 13+).
///
/// O estado não fica em UserDefaults: quem manda é o sistema, e o utilizador pode desligar
/// a app em Definições do Sistema › Geral › Itens de início de sessão. Por isso lê-se sempre
/// `status`. O registo guarda o caminho da app: se a app mudar de sítio (ex.: outra build),
/// é preciso desligar e voltar a ligar.
struct LaunchAtLoginToggle: View {
    @State private var status = SMAppService.mainApp.status
    @State private var error: String?

    var body: some View {
        Toggle("Iniciar o Tradutor ao iniciar sessão", isOn: Binding(
            get: { status == .enabled || status == .requiresApproval },
            set: { setEnabled($0) }
        ))
        if status == .requiresApproval {
            HStack {
                SettingsNote("Falta aprovar o Tradutor nos itens de início de sessão.", kind: .warning)
                Spacer()
                Button("Abrir Definições do Sistema…") { SMAppService.openSystemSettingsLoginItems() }
                    .controlSize(.small)
            }
        }
        if let error {
            SettingsNote(error, kind: .error)
        }
    }

    private func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            error = nil
        } catch {
            self.error = "Não foi possível alterar: \(error.localizedDescription)"
        }
        status = SMAppService.mainApp.status
    }
}
