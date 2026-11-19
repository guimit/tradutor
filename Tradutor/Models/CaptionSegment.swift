import Foundation

/// Um troço de legenda: o texto original (parcial ou confirmado) e, quando existir, a tradução.
struct CaptionSegment: Identifiable, Sendable, Equatable {
    let id: UUID
    var originalText: String
    var detectedLanguage: Language
    /// `nil` até haver tradução (só os segmentos confirmados são traduzidos).
    var translatedText: String?
    var targetLanguage: Language
    /// `false` enquanto for um parcial (texto instável que ainda pode mudar).
    var isConfirmed: Bool
    let timestamp: Date

    init(
        id: UUID = UUID(),
        originalText: String,
        detectedLanguage: Language,
        translatedText: String? = nil,
        targetLanguage: Language,
        isConfirmed: Bool,
        timestamp: Date = .now
    ) {
        self.id = id
        self.originalText = originalText
        self.detectedLanguage = detectedLanguage
        self.translatedText = translatedText
        self.targetLanguage = targetLanguage
        self.isConfirmed = isConfirmed
        self.timestamp = timestamp
    }
}
