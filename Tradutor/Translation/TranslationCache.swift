import Foundation

/// Cache LRU simples de traduções. Em calls e vídeos repetem-se muitas frases curtas
/// ("Yes.", "Thank you.", "Okay."), que assim aparecem traduzidas sem esperar.
struct TranslationCache {
    private struct Key: Hashable {
        var text: String
        var source: TranslationLanguage
        var target: TranslationLanguage
    }

    let capacity: Int
    private var values: [Key: String] = [:]
    /// Do menos para o mais recentemente usado.
    private var order: [Key] = []

    init(capacity: Int = 500) {
        self.capacity = capacity
    }

    var count: Int { values.count }

    mutating func value(for text: String, from source: TranslationLanguage, to target: TranslationLanguage) -> String? {
        let key = Key(text: Self.normalize(text), source: source, target: target)
        guard let value = values[key] else { return nil }
        touch(key)
        return value
    }

    mutating func insert(_ translation: String, for text: String, from source: TranslationLanguage, to target: TranslationLanguage) {
        let key = Key(text: Self.normalize(text), source: source, target: target)
        values[key] = translation
        touch(key)
        if order.count > capacity {
            values[order.removeFirst()] = nil
        }
    }

    private mutating func touch(_ key: Key) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    /// Diferenças de espaços não contam como texto diferente.
    private static func normalize(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
