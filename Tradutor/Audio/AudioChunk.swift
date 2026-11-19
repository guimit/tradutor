import Accelerate
import Foundation

/// Bloco de áudio PCM float32, mono, 16 kHz — o formato que os motores de transcrição esperam.
struct AudioChunk: Sendable {
    static let sampleRate: Double = 16_000

    let samples: [Float]
    /// Segundos desde o início da captação (do primeiro chunk desta sessão).
    let timestamp: TimeInterval

    var duration: TimeInterval { Double(samples.count) / Self.sampleRate }

    /// Nível RMS em dBFS (0 = escala máxima). Silêncio absoluto devolve -160.
    var rmsDecibels: Float {
        guard !samples.isEmpty else { return -160 }
        let rms = vDSP.rootMeanSquare(samples)
        return rms > 0 ? max(20 * log10(rms), -160) : -160
    }
}
