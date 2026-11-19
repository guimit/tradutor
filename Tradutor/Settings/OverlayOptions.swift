import Foundation

/// O que o overlay mostra.
enum OverlayDisplayMode: String, CaseIterable, Identifiable, Sendable {
    case original
    case translation
    case both

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .original: "Só original"
        case .translation: "Só tradução"
        case .both: "Original e tradução"
        }
    }
}

/// Posição do overlay, relativa à área útil do monitor (sem barra de menus nem Dock):
/// `x` é o centro horizontal e `y` o fundo do painel, ambos de 0 a 1.
/// Relativa e não em pontos para continuar a fazer sentido se a resolução mudar.
struct OverlayPosition: Equatable, Sendable {
    var x: Double
    var y: Double

    static let `default` = OverlayPosition(x: 0.5, y: 0.08)
}
