import Foundation
// O WhisperKit ainda não está anotado para Swift 6 (as classes não são Sendable).
// Com @preconcurrency, os avisos de Sendable sobre os seus tipos ficam desligados;
// a segurança garante-se usando cada instância de WhisperKit numa só tarefa de cada vez.
@preconcurrency import WhisperKit

/// Modelos Whisper disponíveis (pastas do repositório argmaxinc/whisperkit-coreml).
enum WhisperModel: String, CaseIterable, Identifiable, Sendable {
    case base = "openai_whisper-base"
    case small = "openai_whisper-small"
    case largeTurbo = "openai_whisper-large-v3-v20240930_turbo_632MB"

    static let `default`: WhisperModel = .small

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .base: "Base (~150 MB, mais rápido)"
        case .small: "Small (~480 MB, mais preciso)"
        case .largeTurbo: "Large v3 Turbo (~630 MB, o mais preciso)"
        }
    }
}

/// Onde ficam os modelos descarregados: ~/Library/Application Support/Tradutor/Models.
enum WhisperModelStore {
    static let repository = "argmaxinc/whisperkit-coreml"

    static var downloadBase: URL {
        URL.applicationSupportDirectory.appending(path: "Tradutor/Models", directoryHint: .isDirectory)
    }

    /// Pasta local do modelo (estrutura criada pelo downloader do WhisperKit).
    static func folder(for model: WhisperModel) -> URL {
        downloadBase.appending(path: "models/\(repository)/\(model.rawValue)", directoryHint: .isDirectory)
    }

    /// O modelo está completo se tiver os três componentes compilados.
    static func isDownloaded(_ model: WhisperModel) -> Bool {
        let folder = folder(for: model)
        return ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc"].allSatisfy {
            FileManager.default.fileExists(atPath: folder.appending(path: $0).path)
        }
    }

    /// Descarrega o modelo (se faltar) e devolve a pasta local.
    static func download(_ model: WhisperModel, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        if isDownloaded(model) { return folder(for: model) }
        return try await WhisperKit.download(
            variant: model.rawValue,
            downloadBase: downloadBase,
            from: repository,
            progressCallback: { progress($0.fractionCompleted) }
        )
    }
}

@MainActor
final class WhisperKitEngine: TranscriptionEngine {
    let configuration: TranscriptionConfiguration
    let model: WhisperModel
    let metrics = TranscriptionMetrics()

    private var recognizer: WhisperKitRecognizer?

    init(configuration: TranscriptionConfiguration, model: WhisperModel = .default) {
        self.configuration = configuration
        self.model = model
    }

    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        guard recognizer == nil else { return }
        let folder = try await WhisperModelStore.download(model, progress: progress)
        progress(1)

        let config = WhisperKitConfig(
            modelFolder: folder.path,
            // O tokenizer é descarregado (uma vez) para a mesma pasta base.
            tokenizerFolder: WhisperModelStore.downloadBase,
            verbose: false,
            logLevel: .error,
            // `prewarm` compila os modelos para o Neural Engine na primeira utilização
            // (pode demorar 1–2 min) e deixa a cache do sistema pronta para as seguintes.
            prewarm: true,
            load: true,
            download: false
        )
        let whisperKit = try await WhisperKit(config)
        recognizer = WhisperKitRecognizer(whisperKit: whisperKit, portugueseVariant: configuration.portugueseVariant)
    }

    func transcribe(_ audio: AsyncStream<AudioChunk>) -> AsyncStream<TranscriptionEvent> {
        guard let recognizer else {
            assertionFailure("prepare() tem de ser chamado antes de transcribe()")
            return AsyncStream { $0.finish() }
        }
        return StreamingTranscription.run(
            StreamingTranscriber(recognizer: recognizer, sourceLanguage: configuration.sourceLanguage, metrics: metrics),
            audio: audio
        )
    }
}

/// Liga um `StreamingTranscriber` a um stream de áudio, numa tarefa própria.
enum StreamingTranscription {
    static func run(_ transcriber: sending StreamingTranscriber, audio: AsyncStream<AudioChunk>) -> AsyncStream<TranscriptionEvent> {
        let (events, continuation) = AsyncStream.makeStream(of: TranscriptionEvent.self)
        let task = Task.detached(priority: .userInitiated) {
            for await chunk in audio {
                for event in await transcriber.process(chunk) { continuation.yield(event) }
            }
            if !Task.isCancelled {
                for event in await transcriber.finish() { continuation.yield(event) }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return events
    }
}

/// Adaptador do WhisperKit para o protocolo `SpeechRecognizer`.
///
/// `@unchecked Sendable`: o `WhisperKit` não é thread-safe, mas cada motor tem uma só
/// tarefa de transcrição ativa, que faz as chamadas em sequência.
final class WhisperKitRecognizer: SpeechRecognizer, @unchecked Sendable {
    private let whisperKit: WhisperKit
    private let prompt: String
    private let promptTokens: [Int]?

    init(whisperKit: WhisperKit, portugueseVariant: PortugueseVariant) {
        self.whisperKit = whisperKit
        // O prompt inicial funciona como "texto anterior": o Whisper tende a continuar no
        // mesmo registo, por isso uma frase com vocabulário típico puxa para a variante certa.
        // O espaço inicial segue a convenção de tokenização do Whisper.
        prompt = Self.prompt(for: portugueseVariant)
        promptTokens = whisperKit.tokenizer?.encode(text: " " + prompt)
    }

    static func prompt(for variant: PortugueseVariant) -> String {
        switch variant {
        case .portugal:
            "Olá, está tudo bem? Estive a ver o ecrã do telemóvel enquanto esperava pelo autocarro."
        case .brazil:
            "Oi, tudo bem? Fiquei olhando a tela do celular enquanto esperava o ônibus."
        }
    }

    func detectLanguage(_ samples: [Float]) async throws -> String? {
        // (sic) o método chama-se mesmo `detectLangauge` na API do WhisperKit.
        try await whisperKit.detectLangauge(audioArray: samples).language
    }

    func transcribe(_ samples: [Float], language: Language) async throws -> [RecognizedSegment] {
        let options = DecodingOptions(
            task: .transcribe,
            language: language.rawValue,
            temperatureFallbackCount: 2,
            usePrefillPrompt: true,
            detectLanguage: false,
            skipSpecialTokens: true,
            // Por defeito o WhisperKit ignora o último 1 s de cada janela (contra alucinações
            // no corte); como a janela acaba onde acaba o áudio captado, queremos tudo.
            windowClipTime: 0,
            promptTokens: language == .portuguese ? promptTokens : nil,
            suppressBlank: true
        )
        let results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: options)
        let usedPrompt = language == .portuguese ? prompt : nil
        return results
            .flatMap(\.segments)
            .filter { !Self.isLikelyHallucination($0, prompt: usedPrompt) }
            .map { RecognizedSegment(text: $0.text, start: TimeInterval($0.start), end: TimeInterval($0.end)) }
    }

    /// O Whisper "inventa" texto em silêncio, em ruído ou no fim de janelas cortadas a meio:
    /// créditos de legendas vistos no treino, loops repetitivos, ou o próprio prompt.
    static func isLikelyHallucination(_ segment: TranscriptionSegment, prompt: String? = nil) -> Bool {
        if segment.noSpeechProb > 0.6 && segment.avgLogprob < -1 { return true }
        // Texto muito repetitivo comprime demasiado bem (o Whisper usa o mesmo limiar, 2,4).
        if segment.compressionRatio > 2.4 { return true }
        if let prompt, Self.repeatsPrompt(segment.text, prompt: prompt) { return true }
        let text = segment.text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        // Anotações em vez de fala: "[BLANK_AUDIO]", "(música)", "*risos*"…
        if let first = text.first, let last = text.last,
           (first == "[" && last == "]") || (first == "(" && last == ")") || (first == "*" && last == "*") {
            return true
        }
        return ["amara.org", "legendas pela comunidade", "subtítulos realizados", "subtitles by"]
            .contains { text.contains($0) }
    }

    /// `true` se o texto contém 4 ou mais palavras seguidas do prompt (fuga do prompt).
    static func repeatsPrompt(_ text: String, prompt: String) -> Bool {
        let words = { (string: String) in
            string.split(whereSeparator: \.isWhitespace).map { FinalDeduplicator.normalize(String($0)) }
        }
        let textWords = words(text)
        let promptWords = words(prompt)
        let length = 4
        guard textWords.count >= length, promptWords.count >= length else { return false }
        let promptGrams = Set((0...(promptWords.count - length)).map { promptWords[$0..<$0 + length].joined(separator: " ") })
        return (0...(textWords.count - length)).contains {
            promptGrams.contains(textWords[$0..<$0 + length].joined(separator: " "))
        }
    }
}
