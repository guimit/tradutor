import Foundation
import Synchronization

/// Medições de latência, escritas pela tarefa de transcrição e lidas pela UI de debug.
final class TranscriptionMetrics: Sendable {
    struct Snapshot: Sendable, Equatable {
        /// Duração da última passagem de reconhecimento (inferência).
        var lastInference: TimeInterval?
        /// Média móvel das passagens.
        var averageInference: TimeInterval?
        /// Áudio processado na última passagem.
        var lastAudioDuration: TimeInterval?
        /// Atraso entre o fim do áudio captado e a emissão do último evento.
        var lastEventDelay: TimeInterval?
        var passCount = 0

        /// Fator de tempo real: tempo de inferência / duração do áudio (< 1 é mais rápido que tempo real).
        var realTimeFactor: Double? {
            guard let lastInference, let lastAudioDuration, lastAudioDuration > 0 else { return nil }
            return lastInference / lastAudioDuration
        }
    }

    private let state = Mutex(Snapshot())

    var snapshot: Snapshot { state.withLock { $0 } }

    func recordPass(inference: TimeInterval, audioDuration: TimeInterval) {
        state.withLock { snapshot in
            snapshot.passCount += 1
            snapshot.lastInference = inference
            snapshot.lastAudioDuration = audioDuration
            let previous = snapshot.averageInference ?? inference
            snapshot.averageInference = previous + (inference - previous) / Double(min(snapshot.passCount, 20))
        }
    }

    func recordEventDelay(_ delay: TimeInterval) {
        state.withLock { $0.lastEventDelay = delay }
    }

    func reset() {
        state.withLock { $0 = Snapshot() }
    }
}
