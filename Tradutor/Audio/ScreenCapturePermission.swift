import AppKit
import CoreGraphics

/// Permissão de "Gravação de Ecrã e Áudio do Sistema" (TCC), exigida pelo ScreenCaptureKit.
///
/// Subtilezas:
/// - `CGPreflightScreenCaptureAccess()` é calculado no arranque do processo: depois de o
///   utilizador ativar a permissão nas Definições, continua a devolver `false` até a app
///   ser reiniciada. Por isso oferecemos sempre um botão para reiniciar.
/// - `CGRequestScreenCaptureAccess()` só mostra o pedido do sistema na primeira vez;
///   depois disso apenas devolve o estado atual.
/// - Com assinatura ad-hoc, cada build novo pode ser visto como uma app diferente,
///   e a permissão tem de ser dada outra vez.
enum ScreenCapturePermission {
    static var isGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Pede a permissão (mostra o pedido do sistema se ainda não foi decidido) e
    /// adiciona a app à lista nas Definições do Sistema.
    @discardableResult
    static func request() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// Abre Definições do Sistema › Privacidade e Segurança › Gravação de Ecrã e Áudio do Sistema.
    @MainActor
    static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }
}
