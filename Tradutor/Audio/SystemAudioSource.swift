import CoreMedia
import Foundation
import ScreenCaptureKit

/// Capta todo o áudio que o Mac reproduz através do ScreenCaptureKit,
/// excluindo o áudio da própria app.
@MainActor
final class SystemAudioSource: AudioSource {
    private var stream: SCStream?
    private var output: StreamOutput?

    /// Erro que fez a captação parar sozinha (ex.: permissão revogada). `nil` se parou normalmente.
    private(set) var stopError: Error?

    func start() async throws -> AsyncStream<AudioChunk> {
        guard stream == nil else { throw AudioSourceError.alreadyRunning }
        stopError = nil

        // Lança um erro (e mostra o pedido do sistema na primeira vez) se não houver permissão.
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw Self.mapError(error)
        }

        // O SCStream exige sempre um filtro de ecrã, mesmo só para áudio.
        // O áudio captado é o de todo o sistema, não só o das apps nesse ecrã.
        guard let display = content.displays.first else { throw AudioSourceError.noDisplay }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        // Pedimos o formato nativo (48 kHz estéreo) e fazemos nós a conversão para 16 kHz mono,
        // para não depender da qualidade do resample interno.
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        // O vídeo não nos interessa, mas não pode ser desligado: reduzimo-lo ao mínimo.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.showsCursor = false

        let (chunks, continuation) = AsyncStream.makeStream(
            of: AudioChunk.self,
            // Se o consumidor atrasar, descartamos o áudio mais antigo (~10 s de margem).
            bufferingPolicy: .bufferingNewest(500)
        )
        let output = StreamOutput(continuation: continuation) { [weak self] error in
            Task { @MainActor in self?.handleUnexpectedStop(error) }
        }
        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)

        do {
            // Também registamos a saída de ecrã (e ignoramos as frames); sem ela o
            // ScreenCaptureKit enche o log com "stream output NOT found. Dropping frame".
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
            try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: output.queue)
            try await stream.startCapture()
        } catch {
            continuation.finish()
            throw Self.mapError(error)
        }

        self.stream = stream
        self.output = output
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in await self?.stop() }
        }
        return chunks
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
        output?.finish()
        output = nil
    }

    private func handleUnexpectedStop(_ error: Error) {
        stopError = Self.mapError(error)
        stream = nil
        output?.finish()
        output = nil
    }

    private static func mapError(_ error: Error) -> Error {
        if let error = error as? SCStreamError, error.code == .userDeclined {
            return AudioSourceError.permissionDenied
        }
        return error
    }
}

/// Recebe as amostras do SCStream na sua própria fila serial, converte-as e envia-as para o stream.
///
/// `@unchecked Sendable`: o estado mutável (conversor, primeiro timestamp) só é usado
/// dentro de `queue`, que é a fila onde o ScreenCaptureKit chama `stream(_:didOutputSampleBuffer:of:)`.
private final class StreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "Tradutor.SystemAudioSource", qos: .userInitiated)

    private let continuation: AsyncStream<AudioChunk>.Continuation
    private let onUnexpectedStop: @Sendable (Error) -> Void
    private let converter = AudioFormatConverter()
    private var firstPresentationTime: CMTime?

    init(
        continuation: AsyncStream<AudioChunk>.Continuation,
        onUnexpectedStop: @escaping @Sendable (Error) -> Void
    ) {
        self.continuation = continuation
        self.onUnexpectedStop = onUnexpectedStop
    }

    func finish() {
        continuation.finish()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid,
              let buffer = AVAudioPCMBuffer.from(sampleBuffer)
        else { return }

        // O PTS está no relógio do sistema; convertemos para segundos desde o primeiro chunk.
        let presentationTime = sampleBuffer.presentationTimeStamp
        let start = firstPresentationTime ?? presentationTime
        firstPresentationTime = start

        guard let samples = try? converter.convert(buffer), !samples.isEmpty else { return }
        let timestamp = (presentationTime - start).seconds
        continuation.yield(AudioChunk(samples: samples, timestamp: timestamp))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        continuation.finish()
        onUnexpectedStop(error)
    }
}
