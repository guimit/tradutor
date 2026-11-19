import Foundation

/// Um troço de legenda: o texto original (parcial ou confirmado) e, quando existir, a tradução.
struct CaptionSegment: Identifiable, Sendable, Equatable {
    let id: UUID
    var originalText: String
    var detectedLanguage: Language
    /// `nil` até haver tradução.
    var translatedText: String?
    /// `false` enquanto `translatedText` for provisória (de um parcial ou de um texto que
    /// entretanto mudou); passa a `true` com a tradução do texto confirmado.
    var isTranslationFinal: Bool
    var targetLanguage: Language
    /// `false` enquanto for um parcial (texto instável que ainda pode mudar).
    var isConfirmed: Bool
    let timestamp: Date

    init(
        id: UUID = UUID(),
        originalText: String,
        detectedLanguage: Language,
        translatedText: String? = nil,
        isTranslationFinal: Bool = false,
        targetLanguage: Language,
        isConfirmed: Bool,
        timestamp: Date = .now
    ) {
        self.id = id
        self.originalText = originalText
        self.detectedLanguage = detectedLanguage
        self.translatedText = translatedText
        self.isTranslationFinal = isTranslationFinal
        self.targetLanguage = targetLanguage
        self.isConfirmed = isConfirmed
        self.timestamp = timestamp
    }

    /// Se origem == destino não se traduz: o próprio original serve de "tradução".
    var needsTranslation: Bool { detectedLanguage != targetLanguage }
}
