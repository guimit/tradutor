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
        static let overlayDisplayMode = "overlayDisplayMode"
        static let overlayFontSize = "overlayFontSize"
        static let overlayBackgroundOpacity = "overlayBackgroundOpacity"
        static let overlayLineCount = "overlayLineCount"
        static let overlayHideDelay = "overlayHideDelay"
        static let overlayPositionX = "overlayPositionX"
        static let overlayPositionY = "overlayPositionY"
        static let overlayScreenName = "overlayScreenName"
        static let translationEngine = "translationEngine"
        static let showLatency = "showLatency"
    }

    static let fontSizeRange: ClosedRange<Double> = 16...64
    static let lineCountRange: ClosedRange<Int> = 1...4
    static let hideDelayRange: ClosedRange<Double> = 2...15

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

    // MARK: Overlay

    var overlayDisplayMode: OverlayDisplayMode {
        didSet { defaults.set(overlayDisplayMode.rawValue, forKey: Key.overlayDisplayMode) }
    }

    var overlayFontSize: Double {
        didSet { defaults.set(overlayFontSize, forKey: Key.overlayFontSize) }
    }

    /// Opacidade do fundo (0 = transparente, 1 = preto opaco).
    var overlayBackgroundOpacity: Double {
        didSet { defaults.set(overlayBackgroundOpacity, forKey: Key.overlayBackgroundOpacity) }
    }

    /// Linhas por bloco de texto (original ou tradução).
    var overlayLineCount: Int {
        didSet { defaults.set(overlayLineCount, forKey: Key.overlayLineCount) }
    }

    /// Segundos sem fala até as legendas desaparecerem.
    var overlayHideDelay: Double {
        didSet { defaults.set(overlayHideDelay, forKey: Key.overlayHideDelay) }
    }

    var overlayPosition: OverlayPosition {
        didSet {
            defaults.set(overlayPosition.x, forKey: Key.overlayPositionX)
            defaults.set(overlayPosition.y, forKey: Key.overlayPositionY)
        }
    }

    /// Nome do monitor escolhido (`NSScreen.localizedName`); `nil` segue o monitor principal.
    /// Se o monitor guardado não estiver ligado, usa-se o principal.
    var overlayScreenName: String? {
        didSet { defaults.set(overlayScreenName, forKey: Key.overlayScreenName) }
    }

    // MARK: Tradução

    var translationEngine: TranslationEngineKind {
        didSet { defaults.set(translationEngine.rawValue, forKey: Key.translationEngine) }
    }

    /// Modo debug: mostra no overlay a latência fala → original → tradução.
    var showLatency: Bool {
        didSet { defaults.set(showLatency, forKey: Key.showLatency) }
    }

    func makeTranslationEngine() -> any TranslationEngine {
        switch translationEngine {
        case .apple: AppleTranslationEngine()
        case .deepL: DeepLEngine()
        case .llm: LLMTranslationEngine()
        }
    }

    /// Com origem fixa igual ao destino, não há nada a traduzir.
    var isTranslationNeeded: Bool {
        sourceLanguage != .fixed(targetLanguage)
    }

    // MARK: Transcrição

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

        overlayDisplayMode = defaults.string(forKey: Key.overlayDisplayMode).flatMap(OverlayDisplayMode.init) ?? .both
        overlayFontSize = (defaults.object(forKey: Key.overlayFontSize) as? Double)?
            .clamped(to: Self.fontSizeRange) ?? 28
        overlayBackgroundOpacity = (defaults.object(forKey: Key.overlayBackgroundOpacity) as? Double)?
            .clamped(to: 0...1) ?? 0.7
        overlayLineCount = (defaults.object(forKey: Key.overlayLineCount) as? Int)?
            .clamped(to: Self.lineCountRange) ?? 2
        overlayHideDelay = (defaults.object(forKey: Key.overlayHideDelay) as? Double)?
            .clamped(to: Self.hideDelayRange) ?? 4
        if let x = defaults.object(forKey: Key.overlayPositionX) as? Double,
           let y = defaults.object(forKey: Key.overlayPositionY) as? Double {
            overlayPosition = OverlayPosition(x: x.clamped(to: 0...1), y: y.clamped(to: 0...1))
        } else {
            overlayPosition = .default
        }
        overlayScreenName = defaults.string(forKey: Key.overlayScreenName)
        translationEngine = defaults.string(forKey: Key.translationEngine).flatMap(TranslationEngineKind.init) ?? .apple
        showLatency = defaults.bool(forKey: Key.showLatency)
    }

    /// Identifica a configuração do motor: se mudar, o motor tem de ser recriado.
    var transcriptionEngineKey: String {
        "\(transcriptionEngine.rawValue)|\(whisperModel.rawValue)|\(sourceLanguage.rawValue)|\(portugueseVariant.rawValue)"
    }

    /// Cria o motor de transcrição escolhido, com a configuração atual.
    func makeTranscriptionEngine() -> any TranscriptionEngine {
        switch transcriptionEngine {
        case .whisperKit: WhisperKitEngine(configuration: transcriptionConfiguration, model: whisperModel)
        case .appleSpeech: AppleSpeechEngine(configuration: transcriptionConfiguration)
        }
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
