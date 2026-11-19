import AppKit
import SwiftUI

/// Painel das legendas: sem borda, transparente, por cima de tudo e sem nunca roubar o foco.
final class OverlayPanel: NSPanel {
    init() {
        // `.nonactivatingPanel`: clicar no painel (no modo de edição) não ativa o Tradutor,
        // por isso a app em uso (ex.: a call) continua com o foco do teclado.
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)

        isFloatingPanel = true
        // Acima das janelas normais e flutuantes (incluindo as de apps em ecrã inteiro),
        // mas abaixo dos menus e dos alertas do sistema.
        level = .statusBar
        // - canJoinAllSpaces: aparece em todos os Spaces, sem ser preciso movê-lo.
        // - fullScreenAuxiliary: pode estar no Space de uma app em ecrã inteiro. Só funciona
        //   porque a app é "accessory" (LSUIElement); numa app normal o painel não entra lá.
        // - stationary: não se mexe no Mission Control nem ao mostrar o secretária.
        // - ignoresCycle: fica fora do ⌘` entre janelas.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Click-through: os cliques passam para a janela de baixo. Desliga-se no modo de edição.
        ignoresMouseEvents = true
        // Por defeito os NSPanel escondem-se quando a app perde o foco; a nossa nunca o tem.
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    // Nunca fica com o teclado: o foco tem de continuar na app que o utilizador está a usar.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// `NSHostingView` que aceita o primeiro clique: sem isto, como a app nunca está ativa,
/// o primeiro clique (início do arrasto, botão "Concluído") seria ignorado.
final class OverlayHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
