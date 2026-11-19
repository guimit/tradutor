import Foundation
import Synchronization
import Testing
@testable import Tradutor

/// Motor falso: devolve "<destino>: <texto>" depois de `delay`, e regista chamadas e cancelamentos.
final class FakeTranslationEngine: TranslationEngine {
    struct State {
        var calls: [String] = []
        var cancelled: [String] = []
    }

    let state = Mutex(State())
    let delay: Duration
    /// Simula um motor que não reage ao cancelamento (o resultado chega na mesma).
    let ignoresCancellation: Bool
    let failing: Set<String>

    init(delay: Duration = .milliseconds(10), ignoresCancellation: Bool = false, failing: Set<String> = []) {
        self.delay = delay
        self.ignoresCancellation = ignoresCancellation
        self.failing = failing
    }

    var calls: [String] { state.withLock { $0.calls } }
    var cancelled: [String] { state.withLock { $0.cancelled } }

    func translate(_ text: String, from source: TranslationLanguage, to target: TranslationLanguage) async throws -> String {
        state.withLock { $0.calls.append(text) }
        if ignoresCancellation {
            // Uma tarefa não estruturada não herda o cancelamento.
            try? await Task.detached { [delay] in try await Task.sleep(for: delay) }.value
        } else {
            do {
                try await Task.sleep(for: delay)
            } catch {
                state.withLock { $0.cancelled.append(text) }
                throw error
            }
        }
        if failing.contains(text) { throw TranslationEngineError.unsupported(source: source, target: target) }
        return "\(target.identifier): \(text)"
    }

    func status(from source: TranslationLanguage, to target: TranslationLanguage) async -> TranslationPairStatus {
        .ready
    }
}

@MainActor
private func waitUntil(timeout: Duration = .seconds(2), _ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while !condition(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor
struct CaptionTranslatorTests {
    let store = CaptionStore()

    private func translator(
        _ engine: FakeTranslationEngine,
        pauseDelay: Duration = .seconds(10)
    ) -> CaptionTranslator {
        var policy = CaptionTranslator.Policy()
        policy.pauseDelay = pauseDelay
        return CaptionTranslator(store: store, engine: engine, portugueseVariant: .portugal, policy: policy)
    }

    private func send(_ event: TranscriptionEvent, to translator: CaptionTranslator, target: Language = .portuguese) {
        store.apply(event, targetLanguage: target)
        translator.update()
    }

    private func partial(_ text: String) -> TranscriptionEvent { .partial(text: text, language: .english) }
    private func final(_ text: String) -> TranscriptionEvent { .final(text: text, language: .english, start: 0, end: 1) }

    @Test func confirmedSegmentIsTranslatedOnce() async {
        let engine = FakeTranslationEngine()
        let translator = translator(engine)
        send(final("Hello everyone."), to: translator)
        await waitUntil { store.segments[0].isTranslationFinal }
        #expect(store.segments[0].translatedText == "pt-PT: Hello everyone.")

        translator.update()
        send(partial("Next"), to: translator)
        #expect(engine.calls == ["Hello everyone."])
    }

    @Test func sameLanguageIsNotTranslated() async {
        let engine = FakeTranslationEngine()
        let translator = translator(engine)
        send(.final(text: "Bom dia a todos.", language: .portuguese, start: 0, end: 1), to: translator)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(engine.calls.isEmpty)
        #expect(store.segments[0].translatedText == nil)
    }

    @Test func shortPartialIsTranslatedOnlyAfterPause() async {
        let engine = FakeTranslationEngine()
        let translator = translator(engine, pauseDelay: .milliseconds(60))
        send(partial("we are going"), to: translator)
        #expect(translator.engineRequestCount == 0)
        send(partial("we are going to"), to: translator)
        await waitUntil { store.segments[0].translatedText != nil }
        // Só o texto que ficou parado durante a pausa.
        #expect(engine.calls == ["we are going to"])
        #expect(store.segments[0].isTranslationFinal == false)
    }

    @Test func partialIsTranslatedInBlocksOfWords() async {
        let engine = FakeTranslationEngine(delay: .milliseconds(100))
        let translator = translator(engine)
        // `engineRequestCount` conta os pedidos no momento; o motor falso só os regista ao arrancar.
        send(partial("one two three four five"), to: translator)
        #expect(translator.engineRequestCount == 0)
        send(partial("one two three four five six"), to: translator)
        send(partial("one two three four five six seven"), to: translator)
        #expect(translator.engineRequestCount == 1)
        send(partial("one two three four five six seven eight nine ten"), to: translator)
        #expect(translator.engineRequestCount == 2)

        await waitUntil { store.segments[0].translatedText != nil }
        // O pedido anterior, ainda em curso, foi cancelado: só o mais recente chega ao ecrã.
        #expect(engine.cancelled == ["one two three four five six"])
        #expect(store.segments[0].translatedText == "pt-PT: one two three four five six seven eight nine ten")
    }

    @Test func finalTranslationReplacesProvisionalAndLateResultsAreIgnored() async {
        let engine = FakeTranslationEngine(delay: .milliseconds(80), ignoresCancellation: true)
        let translator = translator(engine)
        send(partial("today we are going to talk about"), to: translator)
        send(final("Today we are going to talk about the project."), to: translator)

        await waitUntil { store.segments[0].isTranslationFinal }
        #expect(store.segments.count == 1)
        #expect(store.segments[0].translatedText == "pt-PT: Today we are going to talk about the project.")

        // O provisório (que ignora o cancelamento) já terminou e não substituiu o final.
        try? await Task.sleep(for: .milliseconds(150))
        #expect(store.segments[0].translatedText == "pt-PT: Today we are going to talk about the project.")
        #expect(store.segments[0].isTranslationFinal)
    }

    @Test func provisionalTranslationStaysUntilFinalArrives() async {
        let engine = FakeTranslationEngine(delay: .milliseconds(10))
        let translator = translator(engine)
        send(partial("one two three four five six"), to: translator)
        await waitUntil { store.segments[0].translatedText != nil }

        send(final("One, two, three, four, five, six."), to: translator)
        // Logo após o final, ainda se vê a tradução provisória (sem buraco no ecrã).
        #expect(store.segments[0].translatedText == "pt-PT: one two three four five six")
        await waitUntil { store.segments[0].isTranslationFinal }
        #expect(store.segments[0].translatedText == "pt-PT: One, two, three, four, five, six.")
    }

    @Test func repeatedTextComesFromCache() async {
        let engine = FakeTranslationEngine()
        let translator = translator(engine)
        send(final("Thank you."), to: translator)
        await waitUntil { store.segments[0].isTranslationFinal }
        send(partial("Okay"), to: translator)
        send(final("Thank you."), to: translator)
        #expect(store.segments[1].isTranslationFinal)
        #expect(store.segments[1].translatedText == "pt-PT: Thank you.")
        #expect(engine.calls == ["Thank you."])
    }

    @Test func clearingCaptionsCancelsPendingTranslations() async {
        let engine = FakeTranslationEngine(delay: .milliseconds(200))
        let translator = translator(engine)
        send(final("This will be cleared."), to: translator)
        #expect(translator.pendingRequestCount == 1)
        store.clear()
        translator.update()
        #expect(translator.pendingRequestCount == 0)
        await waitUntil { !engine.cancelled.isEmpty }
        #expect(engine.cancelled == ["This will be cleared."])
    }

    @Test func retargetTranslatesAgain() async {
        let engine = FakeTranslationEngine()
        let translator = translator(engine)
        send(final("Good morning."), to: translator)
        await waitUntil { store.segments[0].isTranslationFinal }

        translator.cancelAll()
        store.retarget(to: .spanish)
        translator.update()
        await waitUntil { store.segments[0].isTranslationFinal }
        #expect(store.segments[0].translatedText == "es-ES: Good morning.")
    }

    @Test func failedTranslationIsReportedOnceAndNotRetried() async {
        let engine = FakeTranslationEngine(failing: ["Broken."])
        let translator = translator(engine)
        var errors = 0
        translator.onError = { _ in errors += 1 }
        send(final("Broken."), to: translator)
        await waitUntil { errors == 1 }
        send(partial("more"), to: translator)
        send(partial("more words"), to: translator)
        #expect(engine.calls == ["Broken."])
        #expect(errors == 1)
    }

    @Test func portugueseVariantIsUsedAsTarget() async {
        let engine = FakeTranslationEngine()
        var policy = CaptionTranslator.Policy()
        policy.pauseDelay = .seconds(10)
        let translator = CaptionTranslator(store: store, engine: engine, portugueseVariant: .brazil, policy: policy)
        send(final("Bus."), to: translator)
        await waitUntil { store.segments[0].isTranslationFinal }
        #expect(store.segments[0].translatedText == "pt-BR: Bus.")
    }

    @Test func sentenceSplitByEngineIsTranslatedWhole() async {
        let engine = FakeTranslationEngine()
        let translator = translator(engine)
        send(final("We will split the tasks"), to: translator)
        // O primeiro pedaço é traduzido logo, para não esperar pelo resto.
        await waitUntil { store.segments[0].isTranslationFinal }
        #expect(store.segments[0].translatedText == "pt-PT: We will split the tasks")

        send(partial("for each"), to: translator)
        send(final("for each team."), to: translator)
        await waitUntil { store.segments[0].translatedText == "pt-PT: We will split the tasks for each team." }
        #expect(store.segments[0].isTranslationFinal)
        #expect(store.segments[1].isTranslationMerged)
        #expect(engine.calls == ["We will split the tasks", "We will split the tasks for each team."])

        // A frase acabou: o pedaço seguinte começa uma frase nova.
        send(final("Thanks."), to: translator)
        await waitUntil { store.segments[2].isTranslationFinal }
        #expect(store.segments[2].translatedText == "pt-PT: Thanks.")
        #expect(!store.segments[2].isTranslationMerged)
    }

    @Test func mergedPieceKeepsProvisionalUntilSentenceIsTranslated() async {
        let engine = FakeTranslationEngine(delay: .milliseconds(80))
        let translator = translator(engine)
        send(final("We will split the tasks"), to: translator)
        await waitUntil { store.segments[0].isTranslationFinal }
        send(partial("for each team and every person"), to: translator)
        await waitUntil { store.segments.count == 2 && store.segments[1].translatedText != nil }

        send(final("for each team and every person."), to: translator)
        // Enquanto a frase inteira não chega, os dois pedaços mostram a tradução que tinham.
        #expect(store.segments[0].translatedText == "pt-PT: We will split the tasks")
        #expect(store.segments[1].translatedText == "pt-PT: for each team and every person")
        #expect(!store.segments[1].isTranslationMerged)
        await waitUntil { store.segments[1].isTranslationMerged }
        #expect(store.segments[0].translatedText == "pt-PT: We will split the tasks for each team and every person.")
    }

    @Test func sentencesAreGroupedByPunctuationLanguageAndLength() {
        func segment(_ text: String, _ language: Language = .english, confirmed: Bool = true) -> CaptionSegment {
            CaptionSegment(originalText: text, detectedLanguage: language, targetLanguage: .portuguese, isConfirmed: confirmed)
        }
        let segments = [
            segment("one two"), segment("three four."),           // frase partida em dois
            segment("«Hola»"), segment("y adiós.»", .spanish),    // muda o idioma
            segment("Bom dia", .portuguese),                     // não se traduz: corta a frase
            segment("a b c"), segment("d e f"), segment("g h"),  // passa do limite de palavras
            segment("partial", confirmed: false),
        ]
        let sentences = CaptionTranslator.sentences(in: segments, maximumWords: 6)
            .map { $0.map(\.originalText) }
        #expect(sentences == [
            ["one two", "three four."],
            ["«Hola»"],
            ["y adiós.»"],
            ["a b c", "d e f"],
            ["g h"],
        ])
    }

    @Test func endsSentenceIgnoresClosingQuotes() {
        #expect(CaptionTranslator.endsSentence("Ele disse «olá.»"))
        #expect(CaptionTranslator.endsSentence("Really?\""))
        #expect(CaptionTranslator.endsSentence("Bueno…"))
        #expect(!CaptionTranslator.endsSentence("and then"))
        #expect(!CaptionTranslator.endsSentence(""))
    }
}

struct TranslationCacheTests {
    private let en = TranslationLanguage(language: .english, portugueseVariant: .portugal)
    private let pt = TranslationLanguage(language: .portuguese, portugueseVariant: .portugal)
    private let br = TranslationLanguage(language: .portuguese, portugueseVariant: .brazil)

    @Test func ignoresWhitespaceDifferences() {
        var cache = TranslationCache()
        cache.insert("Olá.", for: "Hello.", from: en, to: pt)
        #expect(cache.value(for: "  Hello. ", from: en, to: pt) == "Olá.")
    }

    @Test func keysIncludeVariant() {
        var cache = TranslationCache()
        cache.insert("autocarro", for: "bus", from: en, to: pt)
        #expect(cache.value(for: "bus", from: en, to: br) == nil)
    }

    @Test func evictsLeastRecentlyUsed() {
        var cache = TranslationCache(capacity: 2)
        cache.insert("a", for: "A", from: en, to: pt)
        cache.insert("b", for: "B", from: en, to: pt)
        _ = cache.value(for: "A", from: en, to: pt)
        cache.insert("c", for: "C", from: en, to: pt)
        #expect(cache.value(for: "B", from: en, to: pt) == nil)
        #expect(cache.value(for: "A", from: en, to: pt) == "a")
        #expect(cache.count == 2)
    }
}
