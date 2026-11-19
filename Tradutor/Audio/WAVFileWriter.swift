import AVFAudio

/// Grava `AudioChunk`s num ficheiro WAV (16 kHz, mono, PCM 16 bits).
final class WAVFileWriter {
    private let file: AVAudioFile
    private(set) var framesWritten = 0

    init(url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: AudioChunk.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        // `settings` é o formato do ficheiro; `commonFormat` é o formato dos buffers
        // que lhe passamos. O AVAudioFile converte float32 → int16 ao escrever.
        file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
    }

    func write(_ samples: [Float]) throws {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: AudioFormatConverter.outputFormat,
                  frameCapacity: AVAudioFrameCount(samples.count)
              )
        else { return }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }
        try file.write(from: buffer)
        framesWritten += samples.count
    }

    /// Fecha o ficheiro e escreve o cabeçalho final do WAV.
    func close() {
        file.close()
    }
}
