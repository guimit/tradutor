import Foundation

// Esqueletos de motores cloud. Não estão ativos por defeito: só são usados se o utilizador
// os escolher em Definições › Tradução (e o texto passa então a sair do Mac).

/// DeepL (https://developers.deepl.com). Por implementar.
///
/// Plano: `POST https://api-free.deepl.com/v2/translate` (ou `api.deepl.com` nas contas pagas),
/// cabeçalho `Authorization: DeepL-Auth-Key <chave>`, corpo JSON
/// `{"text": [...], "source_lang": "EN", "target_lang": "PT-PT"}`. O DeepL aceita PT-PT e PT-BR
/// como destino, mas só "PT" como origem.
struct DeepLEngine: TranslationEngine {
    static let keychainAccount = "deepl-api-key"

    func translate(_ text: String, from source: TranslationLanguage, to target: TranslationLanguage) async throws -> String {
        guard KeychainStore.string(for: Self.keychainAccount) != nil else {
            throw TranslationEngineError.missingAPIKey(engine: "DeepL")
        }
        throw TranslationEngineError.notImplemented(engine: "DeepL")
    }

    func status(from source: TranslationLanguage, to target: TranslationLanguage) async -> TranslationPairStatus {
        .ready
    }

    static func languageCode(_ language: TranslationLanguage, asTarget: Bool) -> String {
        switch language.language {
        case .portuguese: asTarget ? language.portugueseVariant.rawValue.uppercased() : "PT"
        case .english: asTarget ? "EN-US" : "EN"
        case .spanish: "ES"
        }
    }
}

/// Tradução com um LLM (ex.: a API da Anthropic). Por implementar.
///
/// Vantagem sobre os outros motores: pode receber as frases anteriores como contexto, o que
/// ajuda quando a transcrição corta uma frase a meio.
struct LLMTranslationEngine: TranslationEngine {
    static let keychainAccount = "llm-api-key"

    func translate(_ text: String, from source: TranslationLanguage, to target: TranslationLanguage) async throws -> String {
        guard KeychainStore.string(for: Self.keychainAccount) != nil else {
            throw TranslationEngineError.missingAPIKey(engine: "LLM")
        }
        throw TranslationEngineError.notImplemented(engine: "LLM")
    }

    func status(from source: TranslationLanguage, to target: TranslationLanguage) async -> TranslationPairStatus {
        .ready
    }

    /// Instruções a enviar ao modelo.
    static func instructions(from source: TranslationLanguage, to target: TranslationLanguage) -> String {
        """
        Traduz legendas ao vivo de \(source.identifier) para \(target.identifier). \
        Responde só com a tradução, sem comentários. O texto pode ser um fragmento de frase: \
        traduz o fragmento tal como está, sem o completar. Usa o vocabulário e a ortografia \
        próprios de \(target.identifier).
        """
    }
}
