import AppKit

/// Pedaço de texto a mostrar, com o estado (parcial/confirmado) que define a cor.
struct CaptionRun: Equatable, Sendable {
    var id: UUID
    var text: String
    var isConfirmed: Bool
}

struct CaptionWord: Equatable, Sendable {
    var text: String
    var isConfirmed: Bool
}

struct CaptionLine: Identifiable, Equatable, Sendable {
    /// Segmento + posição da primeira palavra. Enquanto se acrescenta texto, as linhas de cima
    /// mantêm o id, e a animação de "subir uma linha" funciona.
    var id: String
    var words: [CaptionWord]
}

/// Quebra o texto em linhas de largura fixa, como nas legendas de TV: as linhas já
/// preenchidas não mudam quando chega texto novo; quando a última enche, tudo sobe uma linha.
///
/// Fazemos a quebra nós (em vez de deixar o `Text` quebrar) para mostrar sempre as
/// *últimas* N linhas com altura estável, e para cada linha ter um id estável.
enum CaptionLineBreaker {
    static func lines(for runs: [CaptionRun], maxWidth: CGFloat, measure: (String) -> CGFloat) -> [CaptionLine] {
        let spaceWidth = measure(" ")
        var lines: [CaptionLine] = []
        var current: CaptionLine?
        var currentWidth: CGFloat = 0

        for run in runs {
            let words = run.text.split(whereSeparator: \.isWhitespace)
            for (index, word) in words.enumerated() {
                let text = String(word)
                let width = measure(text)
                if var line = current, currentWidth + spaceWidth + width <= maxWidth {
                    line.words.append(CaptionWord(text: text, isConfirmed: run.isConfirmed))
                    current = line
                    currentWidth += spaceWidth + width
                } else {
                    // Uma palavra mais larga do que a linha fica sozinha (o `Text` reduz-lhe a escala).
                    if let line = current { lines.append(line) }
                    current = CaptionLine(
                        id: "\(run.id.uuidString)-\(index)",
                        words: [CaptionWord(text: text, isConfirmed: run.isConfirmed)]
                    )
                    currentWidth = width
                }
            }
        }
        if let current { lines.append(current) }
        return lines
    }

    /// Versão com a medição real do tipo de letra.
    static func lines(for runs: [CaptionRun], maxWidth: CGFloat, font: NSFont) -> [CaptionLine] {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        return lines(for: runs, maxWidth: maxWidth) { ($0 as NSString).size(withAttributes: attributes).width }
    }
}
