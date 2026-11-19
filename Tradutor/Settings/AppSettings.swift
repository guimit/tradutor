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
        static let portugueseVariant = "portugueseVariant"
        static let transcriptionEngine = "transcriptionEngine"
        static let whisperModel = "whisperModel"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var sourceLanguage: SourceLanguage {
        didSet { defaults.set(sourceLanguage.rawValue, forKey: Key.sourceLanguage) }
    }

    var targetLanguage: Language {
        didSet { defaults.set(targetLanguage.rawValue, forKey: Key.targetLanguage) }
    }

    var portugueseVariant: PortugueseVariant {
        didSet { defaults.set(portugueseVariant.rawValue, forKey: Key.portugueseVariant) }
    }

    var transcriptionEngine: TranscriptionEngineKind {
        didSet { defaults.set(transcriptionEngine.rawValue, forKey: Key.transcriptionEngine) }
    }

    var whisperModel: WhisperModel {
        didSet { defaults.set(whisperModel.rawValue, forKey: Key.whisperModel) }
    }

    var transcriptionConfiguration: TranscriptionConfiguration {
        TranscriptionConfiguration(sourceLanguage: sourceLanguage, portugueseVariant: portugueseVariant)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        sourceLanguage = defaults.string(forKey: Key.sourceLanguage).flatMap(SourceLanguage.init) ?? .auto
        targetLanguage = defaults.string(forKey: Key.targetLanguage).flatMap(Language.init) ?? .portuguese
        portugueseVariant = defaults.string(forKey: Key.portugueseVariant).flatMap(PortugueseVariant.init) ?? .portugal
        transcriptionEngine = defaults.string(forKey: Key.transcriptionEngine).flatMap(TranscriptionEngineKind.init) ?? .whisperKit
        whisperModel = defaults.string(forKey: Key.whisperModel).flatMap(WhisperModel.init) ?? .default
    }

    /// Cria o motor de transcrição escolhido, com a configuração atual.
    func makeTranscriptionEngine() -> any TranscriptionEngine {
        switch transcriptionEngine {
        case .whisperKit: WhisperKitEngine(configuration: transcriptionConfiguration, model: whisperModel)
        case .appleSpeech: AppleSpeechEngine(configuration: transcriptionConfiguration)
        }
    }
}
