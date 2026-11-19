import Foundation
import Synchronization
import Testing
@testable import Tradutor

// MARK: - Estabilização de idioma

struct LanguageStabilizerTests {
    @Test func adoptsFirstDetectionImmediately() {
        var stabilizer = LanguageStabilizer()
        #expect(stabilizer.observe(.english) == .english)
    }

    @Test func ignoresSingleOutlier() {
        var stabilizer = LanguageStabilizer(initial: .portuguese)
        #expect(stabilizer.observe(.spanish) == .portuguese)
        #expect(stabilizer.observe(.portuguese) == .portuguese)
        #expect(stabilizer.observe(.spanish) == .portuguese)
    }

    @Test func switchesAfterTwoConsecutiveAgreeingWindows() {
        var stabilizer = LanguageStabilizer(initial: .portuguese)
        #expect(stabilizer.observe(.english) == .portuguese)
        #expect(stabilizer.observe(.english) == .english)
    }

    @Test func alternatingCandidatesNeverSwitch() {
        var stabilizer = LanguageStabilizer(initial: .portuguese)
        for language in [Language.english, .spanish, .english, .spanish] {
            #expect(stabilizer.observe(language) == .portuguese)
        }
    }

    @Test func unsupportedDetectionBreaksTheStreak() {
        var stabilizer = LanguageStabilizer(initial: .portuguese)
        stabilizer.observe(.english)
        stabilizer.observe(nil)  // ex.: francês
        #expect(stabilizer.observe(.english) == .portuguese)
        #expect(stabilizer.observe(.english) == .english)
    }

    @Test func unsupportedDetectionBeforeAnyLanguageKeepsNil() {
        var stabilizer = LanguageStabilizer()
        #expect(stabilizer.observe(nil) == nil)
    }

    @Test func respectsCustomAgreement() {
        var stabilizer = LanguageStabilizer(requiredAgreement: 3, initial: .english)
        #expect(stabilizer.observe(.spanish) == .english)
        #expect(stabilizer.observe(.spanish) == .english)
        #expect(stabilizer.observe(.spanish) == .spanish)
    }
}

// MARK: - Deduplicação de finais

struct FinalDeduplicatorTests {
    @Test func rejectsExactRepeatOfSameAudio() {
        var deduplicator = FinalDeduplicator()
        #expect(deduplicator.accept(text: "Olá a todos.", start: 0, end: 1.5) == "Olá a todos.")
        #expect(deduplicator.accept(text: "Olá a todos.", start: 0, end: 1.5) == nil)
    }

    @Test func rejectsFinalContainedInAlreadyFinalizedAudio() {
        var deduplicator = FinalDeduplicator()
        _ = deduplicator.accept(text: "Bom dia, como estás?", start: 0, end: 3)
        #expect(deduplicator.accept(text: "como estás?", start: 1.5, end: 3) == nil)
    }

    @Test func removesWordsRepeatedAcrossTheBoundary() {
        var deduplicator = FinalDeduplicator()
        _ = deduplicator.accept(text: "We need to ship this", start: 0, end: 2)
        #expect(deduplicator.accept(text: "ship this by Friday.", start: 1.6, end: 3.5) == "by Friday.")
    }

    @Test func comparisonIgnoresCaseAndPunctuation() {
        var deduplicator = FinalDeduplicator()
        _ = deduplicator.accept(text: "Vamos a la playa,", start: 0, end: 2)
        #expect(deduplicator.accept(text: "la Playa mañana.", start: 1.9, end: 3) == "mañana.")
    }

    @Test func keepsLegitimateSingleWordRepetition() {
        var deduplicator = FinalDeduplicator()
        _ = deduplicator.accept(text: "Isto é muito", start: 0, end: 1)
        #expect(deduplicator.accept(text: "muito importante.", start: 1.0, end: 2) == "muito importante.")
    }

    @Test func rejectsRepeatedSingleWordFinal() {
        var deduplicator = FinalDeduplicator()
        _ = deduplicator.accept(text: "Obrigado.", start: 0, end: 1)
        #expect(deduplicator.accept(text: "Obrigado.", start: 0.9, end: 1.4) == nil)
    }

    @Test func doesNotTouchFinalsFarApartInTime() {
        var deduplicator = FinalDeduplicator()
        _ = deduplicator.accept(text: "Sim, claro.", start: 0, end: 1)
        #expect(deduplicator.accept(text: "Sim, claro.", start: 10, end: 11) == "Sim, claro.")
    }

    @Test func rejectsEmptyText() {
        var deduplicator = FinalDeduplicator()
        #expect(deduplicator.accept(text: "   ", start: 0, end: 1) == nil)
    }
}

// MARK: - Áudio simulado

/// Gera áudio "falado" em que cada palavra é um tom de 0,4 s com frequência própria.
/// O `FakeRecognizer` faz o caminho inverso: encontra os tons e devolve as palavras.
private enum SyntheticSpeech {
    static let words = ["olá", "bom", "dia", "a", "reunião", "começa", "agora", "vamos",
                        "rever", "o", "plano", "de", "hoje", "com", "toda", "equipa"]
    static let wordDuration = 0.4
    static let wordGap = 0.1
    static let sentenceGap = 0.3

    static func frequency(of wordIndex: Int) -> Double { 300 + Double(wordIndex) * 60 }

    static func tone(_ wordIndex: Int) -> [Float] {
        let count = Int(wordDuration * AudioChunk.sampleRate)
        let frequency = frequency(of: wordIndex)
        return (0..<count).map { Float(0.3 * sin(2 * .pi * frequency * Double($0) / AudioChunk.sampleRate)) }
    }

    static func silence(_ seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * AudioChunk.sampleRate))
    }

    /// Frases (listas de índices de palavras) separadas por pausas curtas.
    static func speech(_ sentences: [[Int]]) -> [Float] {
        var samples: [Float] = []
        for (sentenceIndex, sentence) in sentences.enumerated() {
            if sentenceIndex > 0 { samples += silence(sentenceGap) }
            for (wordIndex, word) in sentence.enumerated() {
                if wordIndex > 0 { samples += silence(wordGap) }
                samples += tone(word)
            }
        }
        return samples
    }

    static func text(_ sentence: [Int]) -> String {
        sentence.map { words[$0] }.joined(separator: " ")
    }

    /// Divide em chunks de 100 ms, como a captação real.
    static func chunks(_ samples: [Float]) -> [AudioChunk] {
        let length = Int(0.1 * AudioChunk.sampleRate)
        return stride(from: 0, to: samples.count, by: length).map { offset in
            AudioChunk(
                samples: Array(samples[offset..<min(offset + length, samples.count)]),
                timestamp: Double(offset) / AudioChunk.sampleRate
            )
        }
    }
}

/// Reconhecedor falso: deteta os tons do `SyntheticSpeech` e agrupa-os em troços
/// (uma pausa ≥ 0,25 s separa troços), como o Whisper faria com frases.
private final class FakeRecognizer: SpeechRecognizer {
    private struct State {
        var transcribeCalls = 0
        var detections: [String?]
        var languagesUsed: [Language] = []
    }

    private let state: Mutex<State>
    /// Simula uma passagem final falhada: devolve vazio quando o áudio acaba em silêncio.
    private let failsOnTrailingSilence: Bool

    init(detections: [String?] = [], failsOnTrailingSilence: Bool = false) {
        state = Mutex(State(detections: detections))
        self.failsOnTrailingSilence = failsOnTrailingSilence
    }

    var transcribeCalls: Int { state.withLock { $0.transcribeCalls } }
    var languagesUsed: [Language] { state.withLock { $0.languagesUsed } }

    /// Devolve as deteções pela ordem dada; esgotada a lista, repete a última.
    func detectLanguage(_ samples: [Float]) async throws -> String? {
        state.withLock {
            $0.detections.count > 1 ? $0.detections.removeFirst() : ($0.detections.first ?? "pt")
        }
    }

    func transcribe(_ samples: [Float], language: Language) async throws -> [RecognizedSegment] {
        state.withLock {
            $0.transcribeCalls += 1
            $0.languagesUsed.append(language)
        }
        let words = Self.findWords(in: samples)
        if failsOnTrailingSilence, let last = words.last,
           Double(samples.count) / AudioChunk.sampleRate - last.end >= 0.25 {
            return []
        }

        var segments: [RecognizedSegment] = []
        var current: [(word: String, start: Double, end: Double)] = []
        func flush() {
            guard let first = current.first, let last = current.last else { return }
            segments.append(RecognizedSegment(text: current.map(\.word).joined(separator: " "), start: first.start, end: last.end))
            current = []
        }
        for word in words {
            if let last = current.last, word.start - last.end >= 0.25 { flush() }
            current.append(word)
        }
        flush()
        return segments
    }

    /// Encontra regiões com som (tramas de 10 ms) e identifica a palavra pela frequência.
    /// Palavras cortadas (mais curtas que 0,35 s) são ignoradas, como um reconhecedor real
    /// ignoraria uma sílaba solta.
    private static func findWords(in samples: [Float]) -> [(word: String, start: Double, end: Double)] {
        let frame = Int(0.01 * AudioChunk.sampleRate)
        var regions: [(start: Int, end: Int)] = []
        var regionStart: Int?
        for offset in stride(from: 0, to: samples.count, by: frame) {
            let slice = samples[offset..<min(offset + frame, samples.count)]
            let loud = slice.contains { abs($0) > 0.05 }
            if loud, regionStart == nil { regionStart = offset }
            if !loud, let start = regionStart {
                regions.append((start, offset))
                regionStart = nil
            }
        }
        if let start = regionStart { regions.append((start, samples.count)) }

        return regions.compactMap { region in
            let duration = Double(region.end - region.start) / AudioChunk.sampleRate
            guard duration >= 0.35 else { return nil }
            let slice = samples[region.start..<region.end]
            let crossings = zip(slice, slice.dropFirst()).filter { ($0 < 0) != ($1 < 0) }.count
            let frequency = Double(crossings) / 2 / duration
            let index = Int(((frequency - 300) / 60).rounded())
            guard SyntheticSpeech.words.indices.contains(index) else { return nil }
            return (SyntheticSpeech.words[index], Double(region.start) / AudioChunk.sampleRate, Double(region.end) / AudioChunk.sampleRate)
        }
    }
}

private func run(
    _ transcriber: StreamingTranscriber,
    _ samples: [Float]
) async -> [TranscriptionEvent] {
    var events: [TranscriptionEvent] = []
    for chunk in SyntheticSpeech.chunks(samples) {
        events += await transcriber.process(chunk)
    }
    events += await transcriber.finish()
    return events
}

private func finals(_ events: [TranscriptionEvent]) -> [(text: String, language: Language, start: Double, end: Double)] {
    events.compactMap {
        if case .final(let text, let language, let start, let end) = $0 { return (text, language, start, end) }
        return nil
    }
}

// MARK: - Streaming

struct StreamingTranscriberTests {
    @Test func silenceNeverCallsTheRecognizer() async {
        let recognizer = FakeRecognizer()
        let transcriber = StreamingTranscriber(recognizer: recognizer, sourceLanguage: .fixed(.portuguese))
        let events = await run(transcriber, SyntheticSpeech.silence(10))
        #expect(events.isEmpty)
        #expect(recognizer.transcribeCalls == 0)
    }

    @Test func separateUtterancesProduceOneFinalEachInOrder() async {
        let recognizer = FakeRecognizer()
        let transcriber = StreamingTranscriber(recognizer: recognizer, sourceLanguage: .fixed(.portuguese))
        let first = [0, 1, 2]
        let second = [7, 8, 9, 10]
        let audio = SyntheticSpeech.silence(1) + SyntheticSpeech.speech([first])
            + SyntheticSpeech.silence(2) + SyntheticSpeech.speech([second]) + SyntheticSpeech.silence(2)

        let result = finals(await run(transcriber, audio))
        #expect(result.map(\.text) == [SyntheticSpeech.text(first), SyntheticSpeech.text(second)])
        // Tempos absolutos: a primeira frase começa a 1 s.
        #expect(abs(result[0].start - 1.0) < 0.05)
        #expect(result[0].end < result[1].start)
    }

    @Test func emitsPartialsBeforeTheFinal() async {
        let transcriber = StreamingTranscriber(recognizer: FakeRecognizer(), sourceLanguage: .fixed(.english))
        let sentence = [3, 4, 5, 6, 7, 8]
        let events = await run(transcriber, SyntheticSpeech.speech([sentence]) + SyntheticSpeech.silence(2))

        let firstFinal = events.firstIndex { if case .final = $0 { true } else { false } }
        let firstPartial = events.firstIndex { if case .partial = $0 { true } else { false } }
        #expect(firstPartial != nil)
        #expect(firstFinal != nil)
        #expect(firstPartial! < firstFinal!)
        #expect(finals(events).map(\.language) == [.english])
    }

    /// Fala contínua (sem pausas que fechem a frase): os finais vão sendo confirmados
    /// pelo caminho e, juntos, contêm cada palavra exatamente uma vez.
    @Test func continuousSpeechNeverDuplicatesFinals() async {
        let transcriber = StreamingTranscriber(recognizer: FakeRecognizer(), sourceLanguage: .fixed(.portuguese))
        let sentences = (0..<14).map { index in (0..<4).map { (index * 3 + $0) % SyntheticSpeech.words.count } }
        let events = await run(transcriber, SyntheticSpeech.speech(sentences) + SyntheticSpeech.silence(2))

        let result = finals(events)
        #expect(result.count > 1, "deviam existir finais antes do fim da fala")
        let emitted = result.map(\.text).joined(separator: " ").split(separator: " ").map(String.init)
        let expected = sentences.flatMap { $0.map { SyntheticSpeech.words[$0] } }
        #expect(emitted == expected)

        // Finais em ordem e sem sobreposição temporal.
        for (previous, next) in zip(result, result.dropFirst()) {
            #expect(previous.end <= next.start + 0.01)
        }
        // Houve finais antes do fim do áudio (confirmação durante a fala).
        let speechEnd = Double(SyntheticSpeech.speech(sentences).count) / AudioChunk.sampleRate
        #expect(result.first!.end < speechEnd - 10)
    }

    @Test func longSentenceWithoutPausesIsForcedToConfirm() async {
        let transcriber = StreamingTranscriber(recognizer: FakeRecognizer(), sourceLanguage: .fixed(.spanish))
        // 50 palavras seguidas, só com pausas de 0,1 s: ~25 s, um único troço.
        let sentence = (0..<50).map { $0 % SyntheticSpeech.words.count }
        let events = await run(transcriber, SyntheticSpeech.speech([sentence]) + SyntheticSpeech.silence(2))

        let result = finals(events)
        #expect(result.count >= 2)
        let emitted = result.map(\.text).joined(separator: " ").split(separator: " ").map(String.init)
        #expect(emitted == sentence.map { SyntheticSpeech.words[$0] })
    }

    @Test func autoLanguageUsesStabilizedDetection() async {
        // pt adotado; um "es" isolado é ignorado; depois "en" duas vezes seguidas muda para inglês.
        let recognizer = FakeRecognizer(detections: ["pt", "es", "pt", "en", "en", "en", "en"])
        var parameters = StreamingTranscriber.Parameters()
        parameters.languageDetectionInterval = 2
        let transcriber = StreamingTranscriber(recognizer: recognizer, sourceLanguage: .auto, parameters: parameters)
        let sentences = (0..<10).map { index in (0..<4).map { (index * 4 + $0) % SyntheticSpeech.words.count } }

        let events = await run(transcriber, SyntheticSpeech.speech(sentences) + SyntheticSpeech.silence(2))
        let languages = events.map {
            switch $0 {
            case .partial(_, let language), .final(_, let language, _, _): language
            }
        }
        // Nunca aparece espanhol, e a mudança pt → en acontece uma só vez.
        #expect(!languages.contains(.spanish))
        #expect(languages.first == .portuguese)
        #expect(languages.last == .english)
        let switches = zip(languages, languages.dropFirst()).filter { $0 != $1 }.count
        #expect(switches == 1)
    }

    @Test func lastPartialBecomesFinalWhenFinalPassComesBackEmpty() async {
        let recognizer = FakeRecognizer(failsOnTrailingSilence: true)
        let transcriber = StreamingTranscriber(recognizer: recognizer, sourceLanguage: .fixed(.portuguese))
        let sentence = [0, 1, 2, 3, 4, 5]
        let events = await run(transcriber, SyntheticSpeech.speech([sentence]) + SyntheticSpeech.silence(2))

        let lastPartial = events.last {
            if case .partial = $0 { true } else { false }
        }
        guard case .partial(let partialText, _)? = lastPartial else {
            Issue.record("sem parciais")
            return
        }
        #expect(finals(events).map(\.text) == [partialText])
    }

    @Test func fixedLanguageNeverDetects() async {
        let recognizer = FakeRecognizer(detections: ["en", "en", "en"])
        let transcriber = StreamingTranscriber(recognizer: recognizer, sourceLanguage: .fixed(.portuguese))
        _ = await run(transcriber, SyntheticSpeech.speech([[0, 1, 2, 3]]) + SyntheticSpeech.silence(2))
        #expect(Set(recognizer.languagesUsed) == [.portuguese])
    }
}

// MARK: - VAD

struct SpeechActivityDetectorTests {
    @Test func silenceIsNotSpeech() {
        var vad = SpeechActivityDetector()
        vad.process(SyntheticSpeech.silence(2))
        #expect(!vad.hasSpeech)
    }

    @Test func toneIsSpeechAndSilenceAfterwardsIsMeasured() {
        var vad = SpeechActivityDetector()
        vad.process(SyntheticSpeech.tone(0))
        #expect(vad.hasSpeech)
        #expect(vad.silenceDuration == 0)
        vad.process(SyntheticSpeech.silence(0.9))
        #expect(abs(vad.silenceDuration - 0.9) < 0.04)
    }

    @Test func shortClickIsIgnored() {
        var vad = SpeechActivityDetector()
        vad.process(Array(SyntheticSpeech.tone(0).prefix(480)) + SyntheticSpeech.silence(0.5))
        #expect(!vad.hasSpeech)
    }
}

// MARK: - Filtro de alucinações do Whisper

struct WhisperHallucinationFilterTests {
    let prompt = WhisperKitRecognizer.prompt(for: .brazil)

    @Test func detectsPromptLeak() {
        #expect(WhisperKitRecognizer.repeatsPrompt(
            "sobre o cronograma. Fiquei olhando a tela do celular enquanto esperava",
            prompt: prompt
        ))
    }

    @Test func ordinarySpeechIsNotAPromptLeak() {
        #expect(!WhisperKitRecognizer.repeatsPrompt(
            "Hoje a gente vai conversar sobre o novo projeto e o cronograma",
            prompt: prompt
        ))
        // Partilhar até 3 palavras com o prompt é normal.
        #expect(!WhisperKitRecognizer.repeatsPrompt("Oi, tudo bem? Vamos começar.", prompt: prompt))
    }
}
