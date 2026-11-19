import AppKit

/// Geometria do overlay. Calculada à parte (e não deixada ao SwiftUI) para a altura do
/// painel ser fixa: não muda com o texto, só com as definições.
struct OverlayLayout: Equatable {
    enum BlockKind: Sendable {
        case original
        case translation
    }

    struct Block: Equatable, Identifiable {
        var kind: BlockKind
        var fontSize: CGFloat
        var lineCount: Int

        var id: BlockKind { kind }
        var lineHeight: CGFloat { OverlayLayout.lineHeight(fontSize: fontSize) }
        var height: CGFloat { lineHeight * CGFloat(lineCount) }
    }

    static let horizontalPadding: CGFloat = 20
    static let verticalPadding: CGFloat = 12
    static let blockSpacing: CGFloat = 6
    static let cornerRadius: CGFloat = 14
    /// Com os dois blocos, o original fica mais pequeno e a tradução em destaque.
    static let secondaryScale: CGFloat = 0.75

    var blocks: [Block]
    var width: CGFloat

    var contentWidth: CGFloat { width - 2 * Self.horizontalPadding }

    var height: CGFloat {
        blocks.map(\.height).reduce(0, +)
            + Self.blockSpacing * CGFloat(max(0, blocks.count - 1))
            + 2 * Self.verticalPadding
    }

    var size: CGSize { CGSize(width: width, height: height) }

    /// Modo efetivo: sem tradução disponível (ainda não implementada, ou origem == destino)
    /// mostra-se só o original, seja qual for a escolha.
    static func effectiveMode(_ mode: OverlayDisplayMode, translationAvailable: Bool) -> OverlayDisplayMode {
        translationAvailable ? mode : .original
    }

    static func make(
        mode: OverlayDisplayMode,
        translationAvailable: Bool,
        fontSize: Double,
        lineCount: Int,
        screenWidth: CGFloat
    ) -> OverlayLayout {
        let size = CGFloat(fontSize)
        let blocks: [Block] = switch effectiveMode(mode, translationAvailable: translationAvailable) {
        case .original: [Block(kind: .original, fontSize: size, lineCount: lineCount)]
        case .translation: [Block(kind: .translation, fontSize: size, lineCount: lineCount)]
        case .both: [
            Block(kind: .original, fontSize: (size * secondaryScale).rounded(), lineCount: lineCount),
            Block(kind: .translation, fontSize: size, lineCount: lineCount),
        ]
        }
        // ~70 % do ecrã: linhas compridas cansam a leitura, curtas fazem o texto subir depressa.
        let width = min(max(screenWidth * 0.7, 420), 1200, screenWidth - 40)
        return OverlayLayout(blocks: blocks, width: width.rounded())
    }

    static func font(size: CGFloat) -> NSFont {
        .systemFont(ofSize: size, weight: .semibold)
    }

    static func lineHeight(fontSize: CGFloat) -> CGFloat {
        let font = font(size: fontSize)
        return ceil(font.ascender - font.descender + font.leading)
    }

    // MARK: - Posição

    /// Moldura do painel para uma posição guardada, sempre dentro da área útil do monitor.
    static func frame(size: CGSize, position: OverlayPosition, in area: CGRect) -> CGRect {
        let x = area.minX + position.x * area.width - size.width / 2
        let y = area.minY + position.y * area.height
        return CGRect(
            x: x.clamped(to: area.minX...max(area.minX, area.maxX - size.width)),
            y: y.clamped(to: area.minY...max(area.minY, area.maxY - size.height)),
            width: size.width,
            height: size.height
        ).integral
    }

    /// Posição relativa de uma moldura (depois de o utilizador a arrastar).
    static func position(of frame: CGRect, in area: CGRect) -> OverlayPosition {
        OverlayPosition(
            x: ((frame.midX - area.minX) / area.width).clamped(to: 0...1),
            y: ((frame.minY - area.minY) / area.height).clamped(to: 0...1)
        )
    }
}
