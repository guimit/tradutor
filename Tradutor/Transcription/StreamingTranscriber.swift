import Foundation

/// Troço reconhecido pelo motor, com tempos relativos ao início do áudio que lhe foi passado.
struct RecognizedSegment: Sendable, Equatable {
    var text: String
    var start: TimeInterval
    var end: TimeInterval
}

/// Reconhecedor "por lotes" (ex.: Whisper): transcreve um bloco de áudio de uma vez.
/// O `StreamingTranscriber` transforma-o num reconhecedor em streaming.
protocol SpeechRecognizer: Sendable {
    /// Código ISO 639-1 do idioma mais provável (pode não ser pt/en/es).
    func detectLanguage(_ samples: [Float]) async throws -> String?
    func transcribe(_ samples: [Float], language: Language) async throws -> [RecognizedSegment]
}

/// Converte um reconhecedor por lotes em streaming com janelas deslizantes.
///
/// Funcionamento:
/// 1. Fora de fala, o buffer guarda só um pequeno pré-roll (o silêncio é descartado).
/// 2. Durante a fala, a cada `step` de áudio novo transcreve-se o buffer inteiro
///    (desde o último ponto confirmado) e emite-se um parcial.
/// 3. Os troços que saem iguais em duas passagens seguidas (exceto o último, que ainda
///    pode mudar) são confirmados: emitidos como finais e retirados do buffer.
/// 4. Uma pausa de `endOfUtteranceSilence` fecha a frase: passagem final e tudo é confirmado.
/// 5. Se o buffer chegar a `maxBufferDuration` (fala sem pausas), força-se a confirmação,
///    porque o Whisper só vê 30 s de cada vez.
///
/// Não é thread-safe: deve ser usado por uma só tarefa.
final class StreamingTranscriber {
    struct Parameters: Sendable {
        var step: TimeInterval = 1.0
        var endOfUtteranceSilence: TimeInterval = 0.8
        var preRoll: TimeInterval = 0.3
        var maxBufferDuration: TimeInterval = 20
        var minimumAudioForPass: TimeInterval = 0.5
        var languageDetectionInterval: TimeInterval = 3
        /// Com menos de ~2 s a deteção de idioma do Whisper erra muito (ex.: "Bom dia" → es),
        /// e a primeira deteção é adotada logo.
        var minimumAudioForDetection: TimeInterval = 2
        var vad = SpeechActivityDetector()
    }

    private let recognizer: any SpeechRecognizer
    private let sourceLanguage: SourceLanguage
    private let metrics: TranscriptionMetrics?
    private var parameters: Parameters

    private var stabilizer = LanguageStabilizer()
    private var deduplicator = FinalDeduplicator()
    private var vad: SpeechActivityDetector

    private var buffer: [Float] = []
    /// Timestamp (s) da primeira amostra de `buffer`.
    private var bufferStart: TimeInterval = 0
    private var inUtterance = false
    private var samplesAtLastPass = 0
    private var totalSamples = 0
    private var totalSamplesAtLastDetection: Int?
    private var previousSegments: [RecognizedSegment] = []
    private var lastPartial: String?

    init(
        recognizer: any SpeechRecognizer,
        sourceLanguage: SourceLanguage,
        parameters: Parameters = Parameters(),
        metrics: TranscriptionMetrics? = nil
    ) {
        self.recognizer = recognizer
        self.sourceLanguage = sourceLanguage
        self.parameters = parameters
        self.metrics = metrics
        self.vad = parameters.vad
    }

    /// Idioma estável atual (útil para debug).
    var currentLanguage: Language? {
        if case .fixed(let language) = sourceLanguage { return language }
        return stabilizer.current
    }

    func process(_ chunk: AudioChunk) async -> [TranscriptionEvent] {
        if buffer.isEmpty { bufferStart = chunk.timestamp }
        buffer.append(contentsOf: chunk.samples)
        totalSamples += chunk.samples.count
        vad.process(chunk.samples)

        if !inUtterance {
            guard vad.hasSpeech else {
                trimToPreRoll()
                return []
            }
            inUtterance = true
        }

        if vad.silenceDuration >= parameters.endOfUtteranceSilence {
            return await finishUtterance()
        }
        if duration(of: buffer.count) >= parameters.maxBufferDuration {
            return await runPass(forceConfirm: true)
        }
        if duration(of: buffer.count - samplesAtLastPass) >= parameters.step {
            return await runPass(forceConfirm: false)
        }
        return []
    }

    /// Fim do áudio: finaliza o que estiver pendente.
    func finish() async -> [TranscriptionEvent] {
        guard inUtterance else { return [] }
        return await finishUtterance()
    }

    // MARK: - Passagens

    private func runPass(forceConfirm: Bool) async -> [TranscriptionEvent] {
        samplesAtLastPass = buffer.count
        guard duration(of: buffer.count) >= parameters.minimumAudioForPass,
              let language = await resolveLanguage(),
              let segments = await recognize(buffer, language: language)
        else { return [] }

        // Quantos troços do início estão confirmados?
        var confirmCount = 0
        if segments.count > 1 {
            for index in 0..<(segments.count - 1) {
                guard index < previousSegments.count,
                      Self.sameText(segments[index].text, previousSegments[index].text)
                else { break }
                confirmCount = index + 1
            }
        }
        if forceConfirm {
            confirmCount = max(confirmCount, segments.count > 1 ? segments.count - 1 : segments.count)
        }

        var events: [TranscriptionEvent] = []
        var remaining = segments
        if confirmCount > 0 {
            let confirmed = Array(segments.prefix(confirmCount))
            events += emitFinals(confirmed, language: language)

            // Corta o áudio até ao fim do último troço confirmado (não até ao fim do buffer:
            // o que vem depois pode ser uma palavra ainda incompleta).
            let cutTime = confirmed.last!.end
            let cutSamples = min(buffer.count, max(0, Int(cutTime * AudioChunk.sampleRate)))
            buffer.removeFirst(cutSamples)
            bufferStart += duration(of: cutSamples)
            samplesAtLastPass = max(0, samplesAtLastPass - cutSamples)
            remaining = segments.dropFirst(confirmCount).map {
                RecognizedSegment(text: $0.text, start: $0.start - cutTime, end: $0.end - cutTime)
            }
        }
        previousSegments = remaining

        let partial = remaining.map(\.text).joined(separator: " ")
        if !partial.isEmpty, partial != lastPartial {
            lastPartial = partial
            events.append(.partial(text: partial, language: language))
        }
        recordDelay(if: !events.isEmpty)
        return events
    }

    private func finishUtterance() async -> [TranscriptionEvent] {
        // Retira o silêncio do fim (deixa uma margem para não cortar a última sílaba).
        let trailing = max(0, vad.silenceDuration - parameters.preRoll)
        let keep = max(0, buffer.count - Int(trailing * AudioChunk.sampleRate))
        let audio = Array(buffer.prefix(keep))

        var events: [TranscriptionEvent] = []
        if duration(of: audio.count) >= parameters.minimumAudioForPass,
           let language = await resolveLanguage(using: audio) {
            var segments = await recognize(audio, language: language) ?? []
            // Se a passagem final falhar ou vier vazia (acontece com alucinações filtradas),
            // o último parcial é a melhor hipótese que temos: não deixamos a frase perder-se.
            if segments.isEmpty, let lastPartial {
                segments = [RecognizedSegment(text: lastPartial, start: 0, end: duration(of: audio.count))]
            }
            events = emitFinals(segments, language: language)
        }

        buffer.removeAll()
        inUtterance = false
        samplesAtLastPass = 0
        previousSegments = []
        lastPartial = nil
        vad.reset()
        recordDelay(if: !events.isEmpty)
        return events
    }

    private func emitFinals(_ segments: [RecognizedSegment], language: Language) -> [TranscriptionEvent] {
        segments.compactMap { segment in
            let start = bufferStart + segment.start
            let end = bufferStart + segment.end
            guard let text = deduplicator.accept(text: segment.text, start: start, end: end) else { return nil }
            return .final(text: text, language: language, start: start, end: end)
        }
    }

    // MARK: - Idioma

    private func resolveLanguage(using audio: [Float]? = nil) async -> Language? {
        if case .fixed(let language) = sourceLanguage { return language }

        let audio = audio ?? buffer
        let due = totalSamplesAtLastDetection.map {
            duration(of: totalSamples - $0) >= parameters.languageDetectionInterval
        } ?? true
        if (stabilizer.current == nil || due),
           duration(of: audio.count) >= parameters.minimumAudioForDetection {
            totalSamplesAtLastDetection = totalSamples
            // Só os últimos 30 s contam (janela do Whisper).
            let window = Array(audio.suffix(Int(30 * AudioChunk.sampleRate)))
            let code = try? await recognizer.detectLanguage(window)
            stabilizer.observe(code.flatMap { Language(rawValue: $0) })
        }
        return stabilizer.current
    }

    // MARK: - Auxiliares

    private func recognize(_ audio: [Float], language: Language) async -> [RecognizedSegment]? {
        let start = ContinuousClock.now
        do {
            let segments = try await recognizer.transcribe(audio, language: language)
            let elapsed = start.duration(to: .now)
            metrics?.recordPass(
                inference: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18,
                audioDuration: duration(of: audio.count)
            )
            return segments
                .map { RecognizedSegment(text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines), start: $0.start, end: $0.end) }
                .filter { !$0.text.isEmpty }
        } catch {
            return nil
        }
    }

    private func trimToPreRoll() {
        let keep = Int(parameters.preRoll * AudioChunk.sampleRate)
        guard buffer.count > keep else { return }
        let drop = buffer.count - keep
        buffer.removeFirst(drop)
        bufferStart += duration(of: drop)
    }

    private func recordDelay(if emitted: Bool) {
        // Tempo de inferência da última passagem: é o atraso entre o fim do áudio e o evento.
        guard emitted, let inference = metrics?.snapshot.lastInference else { return }
        metrics?.recordEventDelay(inference)
    }

    private func duration(of sampleCount: Int) -> TimeInterval {
        Double(sampleCount) / AudioChunk.sampleRate
    }

    private static func sameText(_ a: String, _ b: String) -> Bool {
        let normalize = { (text: String) in
            text.split(whereSeparator: \.isWhitespace).map { FinalDeduplicator.normalize(String($0)) }
        }
        return normalize(a) == normalize(b)
    }
}
