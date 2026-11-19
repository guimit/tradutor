import Foundation

/// Garante que nenhum texto final é emitido duas vezes.
///
/// Os finais podem repetir-se quando o motor volta a transcrever áudio que se sobrepõe
/// ao troço anterior (cortes imprecisos nos timestamps ou reinício de uma janela).
/// Rejeitamos finais inteiramente contidos em áudio já finalizado e removemos as
/// palavras do início que repetem o fim do final anterior.
struct FinalDeduplicator: Sendable {
    /// Distância máxima (s) entre finais para se considerar que podem sobrepor-se.
    var overlapTolerance: TimeInterval = 0.5
    /// Número máximo de palavras repetidas a procurar na fronteira.
    var maxOverlapWords = 8

    private var lastEnd: TimeInterval = -.infinity
    private var lastWords: [String] = []

    /// Devolve o texto a emitir (possivelmente sem as palavras repetidas) ou `nil` se for duplicado.
    mutating func accept(text: String, start: TimeInterval, end: TimeInterval) -> String? {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return nil }

        // Áudio já coberto por finais anteriores.
        if end <= lastEnd + 0.01 { return nil }

        var kept = words
        if start < lastEnd + overlapTolerance {
            let limit = min(maxOverlapWords, lastWords.count, words.count)
            for count in stride(from: limit, through: 1, by: -1) {
                // Uma só palavra repetida pode ser legítima ("muito, muito"), por isso
                // só a removemos quando é o final inteiro.
                guard count >= 2 || count == words.count else { continue }
                let suffix = lastWords.suffix(count).map(Self.normalize)
                let prefix = words.prefix(count).map(Self.normalize)
                if suffix == prefix {
                    kept.removeFirst(count)
                    break
                }
            }
        }
        guard !kept.isEmpty else { return nil }

        lastEnd = end
        lastWords = words
        return kept.joined(separator: " ")
    }

    mutating func reset() {
        lastEnd = -.infinity
        lastWords = []
    }

    /// Minúsculas e sem pontuação, para comparar palavras ("Olá," == "olá").
    static func normalize(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.symbols))
    }
}
