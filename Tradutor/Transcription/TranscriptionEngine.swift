import Foundation

/// Evento produzido por um motor de transcrição.
///
/// - `partial`: hipótese instável do que está a ser dito agora. Cada parcial substitui a
///   anterior e pode mudar por completo.
/// - `final`: texto estável de um troço de áudio. Nunca é repetido nem alterado; depois de um
///   final, o parcial seguinte refere-se apenas ao áudio que ainda não foi finalizado.
///   `start`/`end` em segundos, na mesma escala de `AudioChunk.timestamp`.
enum TranscriptionEvent: Sendable, Equatable {
    case partial(text: String, language: Language)
    case final(text: String, language: Language, start: TimeInterval, end: TimeInterval)
}

/// Opções comuns a todos os motores.
struct TranscriptionConfiguration: Sendable, Equatable {
    var sourceLanguage: SourceLanguage
    var portugueseVariant: PortugueseVariant
}

@MainActor
protocol TranscriptionEngine: AnyObject {
    /// Prepara o motor (descarrega e carrega modelos se for preciso).
    /// `progress` recebe valores de 0 a 1 enquanto houver downloads.
    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws

    /// Transcreve o áudio. O stream de eventos termina quando o áudio termina
    /// (depois de finalizar o que ficou pendente) ou quando o consumidor deixa de o ler.
    func transcribe(_ audio: AsyncStream<AudioChunk>) -> AsyncStream<TranscriptionEvent>

    /// Medições de desempenho, para o modo de debug.
    var metrics: TranscriptionMetrics { get }
}

enum TranscriptionEngineKind: String, CaseIterable, Identifiable, Sendable {
    case whisperKit
    case appleSpeech

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .whisperKit: "WhisperKit"
        case .appleSpeech: "Apple (SpeechAnalyzer)"
        }
    }
}
