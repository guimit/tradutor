import Foundation

/// Idioma de tradução: o idioma da app mais a variante, que só conta para o português.
struct TranslationLanguage: Hashable, Sendable, CustomStringConvertible {
    var language: Language
    var portugueseVariant: PortugueseVariant

    /// Identificador BCP 47 usado pelos motores ("pt-PT", "pt-BR", "en-US", "es-ES").
    var identifier: String {
        switch language {
        case .portuguese: portugueseVariant.rawValue
        case .english: "en-US"
        case .spanish: "es-ES"
        }
    }

    var description: String { identifier }

    var displayName: String {
        language == .portuguese ? portugueseVariant.displayName : language.displayName
    }
}

/// Estado de um par de idiomas num motor.
enum TranslationPairStatus: Sendable, Equatable {
    /// Pronto a traduzir já.
    case ready
    /// Suportado, mas é preciso descarregar os idiomas primeiro.
    case needsDownload
    case unsupported
}

/// Motor de tradução. As implementações têm de aceitar chamadas concorrentes.
protocol TranslationEngine: Sendable {
    func translate(_ text: String, from source: TranslationLanguage, to target: TranslationLanguage) async throws -> String
    func status(from source: TranslationLanguage, to target: TranslationLanguage) async -> TranslationPairStatus
}

enum TranslationEngineError: LocalizedError, Equatable {
    case notInstalled(source: TranslationLanguage, target: TranslationLanguage)
    case unsupported(source: TranslationLanguage, target: TranslationLanguage)
    case missingAPIKey(engine: String)
    case notImplemented(engine: String)

    var errorDescription: String? {
        switch self {
        case .notInstalled(let source, let target):
            "Faltam os idiomas de tradução \(source.displayName) → \(target.displayName). Descarrega-os em Definições › Tradução."
        case .unsupported(let source, let target):
            "O par \(source.displayName) → \(target.displayName) não é suportado por este motor."
        case .missingAPIKey(let engine):
            "Falta a chave de API do \(engine) (Definições › Tradução)."
        case .notImplemented(let engine):
            "O motor \(engine) ainda não está implementado."
        }
    }
}

enum TranslationEngineKind: String, CaseIterable, Identifiable, Sendable {
    case apple
    case deepL
    case llm

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .apple: "Apple (no dispositivo)"
        case .deepL: "DeepL (cloud, por implementar)"
        case .llm: "LLM (cloud, por implementar)"
        }
    }

    /// Motores que enviam texto para fora do Mac.
    var isCloud: Bool { self != .apple }
}
