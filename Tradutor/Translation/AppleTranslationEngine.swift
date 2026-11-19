import Foundation
import Synchronization
import Translation

/// Tradução on-device com a framework Translation.
///
/// Desde o macOS 26, `TranslationSession(installedSource:target:)` cria uma sessão fora do
/// SwiftUI, mas só para idiomas **já instalados** (`canRequestDownloads == false`): se faltarem,
/// `translate` falha com `TranslationError.notInstalled`. O download tem de ser pedido por uma
/// sessão vinda do modificador `.translationTask` numa janela visível, porque o sistema mostra
/// um pedido de confirmação ligado a essa janela (ver `TranslationLanguagesView`).
///
/// `@unchecked Sendable`: a `TranslationSession` não está anotada como Sendable, mas é usada
/// pela própria Apple a partir de várias tarefas; o dicionário de sessões está num `Mutex`.
final class AppleTranslationEngine: TranslationEngine, @unchecked Sendable {
    private let sessions = Mutex<[String: TranslationSession]>([:])

    func translate(_ text: String, from source: TranslationLanguage, to target: TranslationLanguage) async throws -> String {
        let session = await session(from: source, to: target)
        do {
            return try await session.translate(text).targetText
        } catch TranslationError.notInstalled {
            // A sessão fica inutilizável; cria-se outra depois de o utilizador descarregar os idiomas.
            sessions.withLock { $0[Self.key(source, target)] = nil }
            throw TranslationEngineError.notInstalled(source: source, target: target)
        } catch TranslationError.unsupportedLanguagePairing {
            throw TranslationEngineError.unsupported(source: source, target: target)
        }
    }

    func status(from source: TranslationLanguage, to target: TranslationLanguage) async -> TranslationPairStatus {
        let status = await LanguageAvailability().status(
            from: Locale.Language(identifier: source.identifier),
            to: Locale.Language(identifier: target.identifier)
        )
        return switch status {
        case .installed: .ready
        case .supported: .needsDownload
        default: .unsupported
        }
    }

    private func session(from source: TranslationLanguage, to target: TranslationLanguage) async -> TranslationSession {
        let key = Self.key(source, target)
        let sourceLanguage = Locale.Language(identifier: source.identifier)
        let targetLanguage = Locale.Language(identifier: target.identifier)
        let useLowLatency = await isLowLatencyInstalled(from: sourceLanguage, to: targetLanguage)

        // A sessão é criada dentro do lock: não é Sendable, por isso não pode ser criada fora
        // e depois guardada (o compilador não consegue provar que ninguém mais a usa).
        return sessions.withLock { sessions in
            if let session = sessions[key] { return session }
            let session = if #available(macOS 26.4, *), useLowLatency {
                TranslationSession(installedSource: sourceLanguage, target: targetLanguage, preferredStrategy: .lowLatency)
            } else {
                TranslationSession(installedSource: sourceLanguage, target: targetLanguage)
            }
            sessions[key] = session
            return session
        }
    }

    /// `.lowLatency` (macOS 26.4+) usa um modelo mais rápido, mas é um download à parte:
    /// mesmo com o par "instalado", pode faltar (é o caso neste Mac). Só se usa se já existir.
    private func isLowLatencyInstalled(from source: Locale.Language, to target: Locale.Language) async -> Bool {
        guard #available(macOS 26.4, *) else { return false }
        return await LanguageAvailability(preferredStrategy: .lowLatency).status(from: source, to: target) == .installed
    }

    private static func key(_ source: TranslationLanguage, _ target: TranslationLanguage) -> String {
        "\(source.identifier)>\(target.identifier)"
    }
}
