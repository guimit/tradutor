import Foundation
import Observation

/// Definições do utilizador, persistidas em UserDefaults.
/// Usamos uma classe @Observable em vez de @AppStorage para que o pipeline
/// (fora das views) também consiga ler as definições.
@MainActor
@Observable
final class AppSettings {
    private enum Key {
        static let sourceLanguage = "sourceLanguage"
        static let targetLanguage = "targetLanguage"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var sourceLanguage: SourceLanguage {
        didSet { defaults.set(sourceLanguage.rawValue, forKey: Key.sourceLanguage) }
    }

    var targetLanguage: Language {
        didSet { defaults.set(targetLanguage.rawValue, forKey: Key.targetLanguage) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        sourceLanguage = defaults.string(forKey: Key.sourceLanguage).flatMap(SourceLanguage.init) ?? .auto
        targetLanguage = defaults.string(forKey: Key.targetLanguage).flatMap(Language.init) ?? .portuguese
    }
}
