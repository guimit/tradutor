import Foundation

/// Fonte de áudio do pipeline. As implementações entregam sempre áudio no formato
/// de `AudioChunk` (float32, mono, 16 kHz), independentemente do formato nativo.
///
/// Mistura com o microfone (futuro): a ideia é ter uma `MicrophoneAudioSource`
/// com a mesma interface e uma `MixingAudioSource` que combine duas fontes,
/// alinhando os chunks pelo `timestamp`. Ambas podem reutilizar o `AudioFormatConverter`.
/// Alternativa: o ScreenCaptureKit (macOS 15+) também capta o microfone no mesmo
/// `SCStream` (`captureMicrophone` + `SCStreamOutputType.microphone`).
@MainActor
protocol AudioSource: AnyObject {
    /// Começa a captar e devolve o stream de chunks.
    /// O stream termina quando se chama `stop()` ou se a captação falhar.
    func start() async throws -> AsyncStream<AudioChunk>

    /// Para a captação e termina o stream. Pode ser chamado mais do que uma vez.
    func stop() async
}

enum AudioSourceError: LocalizedError {
    case permissionDenied
    case noDisplay
    case alreadyRunning

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Sem autorização para Gravação de Ecrã e Áudio do Sistema."
        case .noDisplay:
            "Não foi encontrado nenhum ecrã para iniciar a captação."
        case .alreadyRunning:
            "A captação já está a decorrer."
        }
    }
}
