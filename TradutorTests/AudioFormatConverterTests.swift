import AVFAudio
import CoreMedia
import Foundation
import Testing
@testable import Tradutor

/// Simula o formato que o ScreenCaptureKit entrega: float32, 48 kHz, estéreo não intercalado.
private let captureFormat = AVAudioFormat(
    commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false
)!

/// Gera `seconds` de áudio dividido em blocos de 1024 frames (como o ScreenCaptureKit).
private func makeBuffers(
    seconds: Double,
    left: (Double) -> Float,
    right: (Double) -> Float
) -> [AVAudioPCMBuffer] {
    let total = Int(seconds * captureFormat.sampleRate)
    var buffers: [AVAudioPCMBuffer] = []
    var frame = 0
    while frame < total {
        let count = min(1024, total - frame)
        let buffer = AVAudioPCMBuffer(pcmFormat: captureFormat, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        for i in 0..<count {
            let time = Double(frame + i) / captureFormat.sampleRate
            buffer.floatChannelData![0][i] = left(time)
            buffer.floatChannelData![1][i] = right(time)
        }
        buffers.append(buffer)
        frame += count
    }
    return buffers
}

private func sine(_ frequency: Double, amplitude: Float = 0.5) -> (Double) -> Float {
    { time in amplitude * Float(sin(2 * .pi * frequency * time)) }
}

struct AudioFormatConverterTests {
    @Test func convertsToSixteenKilohertzMono() throws {
        let converter = AudioFormatConverter()
        let buffers = makeBuffers(seconds: 1, left: sine(440), right: sine(440))
        let output = try buffers.flatMap { try converter.convert($0) }

        // 1 s a 48 kHz → ~16 000 amostras (o resampler pode reter algumas no fim).
        #expect(abs(output.count - 16_000) < 100)

        // A frequência mantém-se: ~880 passagens por zero num segundo de 440 Hz.
        let zeroCrossings = zip(output, output.dropFirst()).filter { ($0 < 0) != ($1 < 0) }.count
        #expect(abs(zeroCrossings - 880) < 10)

        // Amplitude preservada: RMS de um seno de 0,5 ≈ 0,354 (≈ -9 dBFS).
        let chunk = AudioChunk(samples: Array(output.dropFirst(1_000)), timestamp: 0)
        #expect(abs(chunk.rmsDecibels - (-9.03)) < 0.5)
    }

    @Test func mixesBothChannelsInsteadOfKeepingOnlyTheLeft() throws {
        // Canal direito em oposição de fase ao esquerdo: misturados, cancelam-se.
        // Se o conversor ficasse só com o esquerdo, o resultado teria sinal.
        let converter = AudioFormatConverter()
        let buffers = makeBuffers(seconds: 0.5, left: sine(440), right: { -sine(440)($0) })
        let output = try buffers.flatMap { try converter.convert($0) }

        #expect(!output.isEmpty)
        #expect(output.map(abs).max()! < 0.01)
    }

    @Test func rightChannelOnlyIsNotLost() throws {
        let converter = AudioFormatConverter()
        let buffers = makeBuffers(seconds: 0.5, left: { _ in 0 }, right: sine(440))
        let output = try buffers.flatMap { try converter.convert($0) }

        #expect(output.map(abs).max()! > 0.1)
    }

    @Test func copiesPCMFromSampleBuffer() throws {
        let source = makeBuffers(seconds: 1024 / 48_000, left: sine(440), right: sine(220))[0]
        let sampleBuffer = try makeSampleBuffer(from: source)

        let copy = try #require(AVAudioPCMBuffer.from(sampleBuffer))
        #expect(copy.frameLength == source.frameLength)
        #expect(copy.format.sampleRate == 48_000)
        #expect(copy.format.channelCount == 2)
        for channel in 0..<2 {
            for i in [0, 100, 1023] {
                #expect(copy.floatChannelData![channel][i] == source.floatChannelData![channel][i])
            }
        }
    }

    /// Embrulha um AVAudioPCMBuffer num CMSampleBuffer, como os que o ScreenCaptureKit entrega.
    private func makeSampleBuffer(from buffer: AVAudioPCMBuffer) throws -> CMSampleBuffer {
        var formatDescription: CMAudioFormatDescription?
        var status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: buffer.format.streamDescription,
            layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        try #require(status == noErr)

        var sampleBuffer: CMSampleBuffer?
        status = CMAudioSampleBufferCreateWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription!,
            sampleCount: CMItemCount(buffer.frameLength),
            presentationTimeStamp: CMTime(value: 0, timescale: 48_000),
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        )
        try #require(status == noErr)

        status = CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer!,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: buffer.audioBufferList
        )
        try #require(status == noErr)
        return sampleBuffer!
    }
}

struct WAVFileWriterTests {
    @Test func writesReadableSixteenKilohertzMonoWAV() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try WAVFileWriter(url: url)
        let samples = (0..<16_000).map { Float(sin(2 * .pi * 440 * Double($0) / 16_000)) * 0.5 }
        try writer.write(Array(samples.prefix(10_000)))
        try writer.write(Array(samples.dropFirst(10_000)))
        writer.close()
        #expect(writer.framesWritten == 16_000)

        let file = try AVAudioFile(forReading: url)
        #expect(file.length == 16_000)
        #expect(file.fileFormat.sampleRate == 16_000)
        #expect(file.fileFormat.channelCount == 1)
        #expect(file.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int == 16)
    }
}

struct AudioChunkTests {
    @Test func silenceHasFloorLevel() {
        #expect(AudioChunk(samples: [0, 0, 0], timestamp: 0).rmsDecibels == -160)
        #expect(AudioChunk(samples: [], timestamp: 0).rmsDecibels == -160)
    }

    @Test func fullScaleSquareWaveIsZeroDecibels() {
        let chunk = AudioChunk(samples: [1, -1, 1, -1], timestamp: 0)
        #expect(abs(chunk.rmsDecibels) < 0.001)
        #expect(abs(AudioChunk(samples: Array(repeating: 0.5, count: 160), timestamp: 0).duration - 0.01) < 1e-9)
    }
}
