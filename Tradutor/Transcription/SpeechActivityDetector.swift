import Accelerate

/// VAD simples por energia, em tramas de 30 ms.
///
/// Suficiente para áudio do sistema (normalmente limpo): o objetivo é não gastar inferência
/// em silêncio e saber quando uma frase acabou, não distinguir voz de música.
struct SpeechActivityDetector: Sendable {
    /// Nível (dBFS) acima do qual uma trama conta como som.
    var thresholdDecibels: Float = -45
    /// Tramas seguidas acima do limiar para começar a contar como fala (evita cliques).
    var framesToStart = 3

    static let frameLength = Int(AudioChunk.sampleRate * 0.03)

    /// `true` desde que começou fala e até `reset()`. A pausa mede-se com `silenceDuration`.
    private(set) var hasSpeech = false
    /// Tempo desde a última trama com som (0 enquanto houver som).
    private(set) var silenceDuration: TimeInterval = 0

    private var pending: [Float] = []
    private var loudStreak = 0

    mutating func process(_ samples: [Float]) {
        pending.append(contentsOf: samples)
        var offset = 0
        while pending.count - offset >= Self.frameLength {
            let frame = pending[offset..<offset + Self.frameLength]
            offset += Self.frameLength
            processFrame(frame)
        }
        pending.removeFirst(offset)
    }

    /// Esquece a fala anterior (mantém o estado de silêncio).
    mutating func reset() {
        hasSpeech = false
        loudStreak = 0
    }

    private mutating func processFrame(_ frame: ArraySlice<Float>) {
        let rms = vDSP.rootMeanSquare(frame)
        let decibels = rms > 0 ? 20 * log10(rms) : -160
        let frameDuration = Double(Self.frameLength) / AudioChunk.sampleRate

        if decibels > thresholdDecibels {
            loudStreak += 1
            if loudStreak >= framesToStart { hasSpeech = true }
            if hasSpeech { silenceDuration = 0 } else { silenceDuration += frameDuration }
        } else {
            loudStreak = 0
            silenceDuration += frameDuration
        }
    }
}
