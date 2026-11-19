import AVFAudio
import Foundation

/// Lê um ficheiro de áudio e entrega-o como se fosse captado ao vivo.
/// Serve para testar a transcrição sem depender da permissão de captação nem de áudio a tocar.
@MainActor
final class FileAudioSource: AudioSource {
    let url: URL
    /// `true` entrega o áudio ao ritmo real (como ao vivo); `false` o mais depressa possível.
    let realTime: Bool
    /// Silêncio acrescentado no fim, para o VAD detetar o fim da última frase.
    let trailingSilence: TimeInterval

    private var task: Task<Void, Never>?

    init(url: URL, realTime: Bool = true, trailingSilence: TimeInterval = 1.5) {
        self.url = url
        self.realTime = realTime
        self.trailingSilence = trailingSilence
    }

    func start() async throws -> AsyncStream<AudioChunk> {
        guard task == nil else { throw AudioSourceError.alreadyRunning }
        let samples = try Self.loadSamples(from: url)
            + [Float](repeating: 0, count: Int(trailingSilence * AudioChunk.sampleRate))
        let realTime = realTime

        let (chunks, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        task = Task.detached {
            let chunkLength = Int(AudioChunk.sampleRate * 0.1)
            var offset = 0
            let clock = ContinuousClock()
            let start = clock.now
            while offset < samples.count, !Task.isCancelled {
                let end = min(offset + chunkLength, samples.count)
                let timestamp = Double(offset) / AudioChunk.sampleRate
                if realTime {
                    try? await clock.sleep(until: start.advanced(by: .seconds(timestamp + 0.1)))
                }
                continuation.yield(AudioChunk(samples: Array(samples[offset..<end]), timestamp: timestamp))
                offset = end
            }
            continuation.finish()
        }
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.task?.cancel() }
        }
        return chunks
    }

    func stop() async {
        task?.cancel()
        task = nil
    }

    /// Lê o ficheiro inteiro e converte para float32, mono, 16 kHz.
    nonisolated static func loadSamples(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let converter = AudioFormatConverter()
        var samples: [Float] = []
        let blockLength: AVAudioFrameCount = 16_384
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: blockLength) else { break }
            try file.read(into: buffer, frameCount: blockLength)
            if buffer.frameLength == 0 { break }
            samples += try converter.convert(buffer)
        }
        return samples
    }
}
