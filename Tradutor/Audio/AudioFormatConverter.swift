import AVFAudio
import CoreMedia

/// Converte áudio em qualquer formato PCM para float32, mono, 16 kHz.
///
/// Não é thread-safe: o `AVAudioConverter` guarda estado entre chamadas (o filtro de
/// resample precisa das amostras anteriores), por isso deve ser usado sempre a partir
/// da mesma fila e com o áudio pela ordem em que chega.
final class AudioFormatConverter {
    static let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: AudioChunk.sampleRate,
        channels: 1,
        interleaved: false
    )!

    private var converter: AVAudioConverter?

    func convert(_ input: AVAudioPCMBuffer) throws -> [Float] {
        let converter = try converter(for: input.format)
        let outputFormat = Self.outputFormat

        // Margem extra: o resampler pode libertar amostras que tinha retidas da chamada anterior.
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return []
        }

        // O bloco é chamado até o conversor ter dados suficientes. Entregamos o buffer uma
        // vez e depois `.noDataNow` — não `.endOfStream`, que reiniciaria o resampler e
        // criaria descontinuidades entre chunks.
        var delivered = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if delivered {
                inputStatus.pointee = .noDataNow
                return nil
            }
            delivered = true
            inputStatus.pointee = .haveData
            return input
        }
        if status == .error, let error { throw error }

        guard let channel = output.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }

    private func converter(for inputFormat: AVAudioFormat) throws -> AVAudioConverter {
        if let converter, converter.inputFormat == inputFormat {
            return converter
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: Self.outputFormat) else {
            throw CocoaError(.featureUnsupported)
        }
        // Por defeito, ao passar de estéreo para mono o conversor fica só com o canal
        // esquerdo. Com `downmix` mistura os dois canais.
        converter.downmix = true
        self.converter = converter
        return converter
    }
}

extension AVAudioPCMBuffer {
    /// Copia o áudio PCM de um `CMSampleBuffer` (como os do ScreenCaptureKit) para um `AVAudioPCMBuffer`.
    static func from(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        // Via ASBD: `init(cmAudioFormatDescription:)` está obsoleto no macOS 27 e o
        // substituto `init(formatDescription:)` só existe a partir do 27.
        guard var description = sampleBuffer.formatDescription?.audioStreamBasicDescription else { return nil }
        let frameCount = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frameCount > 0,
              let format = AVAudioFormat(streamDescription: &description),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        else { return nil }

        buffer.frameLength = frameCount
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: buffer.mutableAudioBufferList
        )
        return status == noErr ? buffer : nil
    }
}
