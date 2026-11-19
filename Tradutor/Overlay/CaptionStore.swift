import Foundation
import Observation

/// Legendas atuais, alimentadas pelos eventos de transcrição.
///
/// Há no máximo um segmento não confirmado (o parcial), sempre no fim. Um final substitui
/// esse parcial mantendo o mesmo `id`, para a UI trocar o texto no sítio em vez de o mover.
@MainActor
@Observable
final class CaptionStore {
    private(set) var segments: [CaptionSegment] = []
    /// Muda a cada evento; serve para detetar atividade (e silêncio).
    private(set) var revision = 0

    /// Limite de segmentos guardados. Ao passar o limite corta-se metade de uma vez
    /// (a quebra de linhas recomeça do início, por isso cortes frequentes fariam o texto saltar).
    let maxSegments: Int

    init(maxSegments: Int = 40) {
        self.maxSegments = maxSegments
    }

    func apply(_ event: TranscriptionEvent, targetLanguage: Language, now: Date = .now) {
        switch event {
        case .partial(let text, let language):
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            if let last = segments.last, !last.isConfirmed {
                segments[segments.count - 1].originalText = text
                segments[segments.count - 1].detectedLanguage = language
            } else {
                segments.append(CaptionSegment(
                    originalText: text, detectedLanguage: language,
                    targetLanguage: targetLanguage, isConfirmed: false, timestamp: now
                ))
            }

        case .final(let text, let language, _, _):
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let last = segments.last, !last.isConfirmed {
                if text.isEmpty {
                    segments.removeLast()
                } else {
                    segments[segments.count - 1].originalText = text
                    segments[segments.count - 1].detectedLanguage = language
                    segments[segments.count - 1].isConfirmed = true
                }
            } else if !text.isEmpty {
                segments.append(CaptionSegment(
                    originalText: text, detectedLanguage: language,
                    targetLanguage: targetLanguage, isConfirmed: true, timestamp: now
                ))
            }
        }
        if segments.count > maxSegments {
            segments.removeFirst(segments.count - maxSegments / 2)
        }
        revision += 1
    }

    /// Guarda a tradução de um segmento confirmado (usado pela fase de tradução).
    func setTranslation(_ text: String, for id: CaptionSegment.ID) {
        guard let index = segments.firstIndex(where: { $0.id == id }) else { return }
        segments[index].translatedText = text
        revision += 1
    }

    func clear() {
        guard !segments.isEmpty else { return }
        segments.removeAll()
    }
}
