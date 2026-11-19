import Foundation

/// Decide o que traduzir e quando, a partir das legendas do `CaptionStore`.
///
/// Estratégia de latência:
/// 1. O original (parcial) aparece logo; a tradução vem por cima, quando houver.
/// 2. Traduz-se o texto confirmado e, enquanto a frase ainda decorre, blocos provisórios do
///    parcial: quando chega a `minimumWords` palavras e depois a cada `wordStep` palavras novas,
///    ou numa pausa curta (`pauseDelay` sem o parcial mudar).
/// 3. A tradução provisória fica visível (no mesmo segmento, com o mesmo id) até chegar a do
///    texto confirmado, que a substitui no sítio.
/// 4. Um pedido novo para um segmento cancela o anterior, e os resultados que chegam
///    depois de cancelados ou de o segmento desaparecer são ignorados.
///
/// Segmentação em frases: o motor de transcrição às vezes confirma uma frase aos pedaços
/// ("We will split the tasks" + "for each team."). Traduzidos em separado, os pedaços dão
/// traduções erradas. Por isso os segmentos confirmados seguidos, no mesmo idioma, juntam-se
/// numa frase até aparecer pontuação final (ou `maximumSentenceWords`); a frase é traduzida
/// inteira e a tradução fica no primeiro segmento. O primeiro pedaço é traduzido logo
/// (para não esperar) e de novo quando a frase cresce.
///
/// Chama-se `update()` depois de cada mudança no `CaptionStore`.
@MainActor
final class CaptionTranslator {
    struct Policy: Sendable {
        var minimumWords = 6
        var wordStep = 4
        var pauseDelay: Duration = .milliseconds(600)
        var minimumWordsOnPause = 3
        /// Uma frase sem pontuação final não cresce para lá disto (motores sem pontuação).
        var maximumSentenceWords = 30
    }

    /// Uma tradução que chegou: para as métricas de latência.
    struct Delivery: Sendable {
        /// Todos os segmentos da frase traduzida (o primeiro tem a tradução).
        var segmentIDs: [CaptionSegment.ID]
        var isFinal: Bool
        var fromCache: Bool
    }

    private struct Request {
        var task: Task<Void, Never>
        var text: String
        var merged: [CaptionSegment.ID]
        var isFinal: Bool
        var generation: Int
    }

    private let store: CaptionStore
    private let engine: any TranslationEngine
    private let portugueseVariant: PortugueseVariant
    private let policy: Policy

    private var cache = TranslationCache()
    private var requests: [CaptionSegment.ID: Request] = [:]
    /// Palavras do parcial no último pedido provisório, por segmento.
    private var provisionalWordCount: [CaptionSegment.ID: Int] = [:]
    private var provisionalText: [CaptionSegment.ID: String] = [:]
    /// Texto da frase cuja tradução final está no ecrã, pelo primeiro segmento da frase.
    private var finalText: [CaptionSegment.ID: String] = [:]
    /// Frases cuja tradução final falhou: não se repete a cada evento.
    private var failed: [CaptionSegment.ID: String] = [:]
    private var pauseTask: Task<Void, Never>?
    private var generation = 0

    var onDelivery: (Delivery) -> Void = { _ in }
    var onError: (Error) -> Void = { _ in }

    /// Pedidos feitos ao motor (sem contar os da cache). Para testes e debug.
    private(set) var engineRequestCount = 0

    init(
        store: CaptionStore,
        engine: any TranslationEngine,
        portugueseVariant: PortugueseVariant,
        policy: Policy = Policy()
    ) {
        self.store = store
        self.engine = engine
        self.portugueseVariant = portugueseVariant
        self.policy = policy
    }

    isolated deinit {
        cancelAll()
    }

    var pendingRequestCount: Int { requests.count }

    func update() {
        // Segmentos que desapareceram (limpeza após silêncio, limite do store).
        let ids = Set(store.segments.map(\.id))
        for (id, request) in requests where !ids.contains(id) {
            request.task.cancel()
            requests[id] = nil
        }
        provisionalWordCount = provisionalWordCount.filter { ids.contains($0.key) }
        provisionalText = provisionalText.filter { ids.contains($0.key) }
        finalText = finalText.filter { ids.contains($0.key) }
        failed = failed.filter { ids.contains($0.key) }

        for sentence in Self.sentences(in: store.segments, maximumWords: policy.maximumSentenceWords) {
            let head = sentence[0]
            let merged = sentence.dropFirst().map(\.id)
            let text = sentence.map(\.originalText).joined(separator: " ")
            // Os pedaços seguintes já não precisam da sua tradução provisória.
            for id in merged {
                requests.removeValue(forKey: id)?.task.cancel()
            }
            let pending = requests[head.id]
            guard finalText[head.id] != text, failed[head.id] != text,
                  pending?.isFinal != true || pending?.text != text
            else { continue }
            request(head, text: text, merged: merged, isFinal: true)
        }

        if let segment = store.segments.last, !segment.isConfirmed, segment.needsTranslation {
            let words = Self.wordCount(segment.originalText)
            let previous = provisionalWordCount[segment.id]
            if words >= policy.minimumWords, previous.map({ words - $0 >= policy.wordStep }) ?? true {
                request(segment, text: segment.originalText, isFinal: false)
            }
        }
        schedulePauseCheck()
    }

    func cancelAll() {
        pauseTask?.cancel()
        pauseTask = nil
        for request in requests.values { request.task.cancel() }
        requests.removeAll()
        provisionalWordCount.removeAll()
        provisionalText.removeAll()
        finalText.removeAll()
        failed.removeAll()
    }

    /// Junta os segmentos confirmados (a traduzir) em frases: segmentos seguidos no mesmo
    /// idioma, até um acabar com pontuação final ou a frase chegar a `maximumWords`.
    static func sentences(in segments: [CaptionSegment], maximumWords: Int) -> [[CaptionSegment]] {
        var sentences: [[CaptionSegment]] = []
        var current: [CaptionSegment] = []
        var words = 0
        func close() {
            if !current.isEmpty { sentences.append(current) }
            current = []
            words = 0
        }
        for segment in segments {
            guard segment.isConfirmed, segment.needsTranslation else {
                close()
                continue
            }
            let count = wordCount(segment.originalText)
            if let last = current.last,
               last.detectedLanguage != segment.detectedLanguage || words + count > maximumWords {
                close()
            }
            current.append(segment)
            words += count
            if endsSentence(segment.originalText) { close() }
        }
        close()
        return sentences
    }

    /// Pontuação final, ignorando aspas/parênteses de fecho ("Disse «olá.»").
    static func endsSentence(_ text: String) -> Bool {
        let closing: Set<Character> = ["\"", "'", "»", "”", "’", ")", "]"]
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last(where: { !closing.contains($0) })
        else { return false }
        return [".", "!", "?", "…"].contains(last)
    }

    // MARK: - Pedidos

    private func request(_ segment: CaptionSegment, text: String, merged: [CaptionSegment.ID] = [], isFinal: Bool) {
        let source = language(segment.detectedLanguage)
        let target = language(segment.targetLanguage)
        let id = segment.id

        if !isFinal {
            provisionalWordCount[id] = Self.wordCount(text)
            provisionalText[id] = text
        }
        requests[id]?.task.cancel()
        requests[id] = nil

        if let cached = cache.value(for: text, from: source, to: target) {
            deliver(cached, text: text, id: id, merged: merged, isFinal: isFinal, fromCache: true)
            return
        }

        generation += 1
        let generation = generation
        engineRequestCount += 1
        let task = Task { [weak self, engine] in
            let result: Result<String, Error>
            do {
                result = .success(try await engine.translate(text, from: source, to: target))
            } catch {
                result = .failure(error)
            }
            guard !Task.isCancelled else { return }
            self?.complete(id: id, generation: generation, source: source, target: target, result: result)
        }
        requests[id] = Request(task: task, text: text, merged: merged, isFinal: isFinal, generation: generation)
    }

    private func complete(
        id: CaptionSegment.ID,
        generation: Int,
        source: TranslationLanguage,
        target: TranslationLanguage,
        result: Result<String, Error>
    ) {
        // Só o pedido mais recente de cada segmento conta.
        guard let request = requests[id], request.generation == generation else { return }
        requests[id] = nil
        switch result {
        case .success(let translation):
            cache.insert(translation, for: request.text, from: source, to: target)
            deliver(translation, text: request.text, id: id, merged: request.merged, isFinal: request.isFinal, fromCache: false)
        case .failure(let error):
            if request.isFinal { failed[id] = request.text }
            onError(error)
        }
    }

    private func deliver(_ translation: String, text: String, id: CaptionSegment.ID, merged: [CaptionSegment.ID], isFinal: Bool, fromCache: Bool) {
        if isFinal { finalText[id] = text }
        store.setTranslation(translation, for: id, isFinal: isFinal, merged: merged)
        onDelivery(Delivery(segmentIDs: [id] + merged, isFinal: isFinal, fromCache: fromCache))
    }

    /// Pausa curta: se o parcial não mudar durante `pauseDelay`, traduz-se o que houver.
    private func schedulePauseCheck() {
        pauseTask?.cancel()
        guard let last = store.segments.last, !last.isConfirmed, last.needsTranslation else { return }
        let id = last.id
        let text = last.originalText
        pauseTask = Task { [weak self, policy] in
            try? await Task.sleep(for: policy.pauseDelay)
            guard !Task.isCancelled, let self,
                  let segment = self.store.segments.last, segment.id == id, segment.originalText == text,
                  !segment.isConfirmed,
                  Self.wordCount(text) >= policy.minimumWordsOnPause,
                  self.provisionalText[id] != text
            else { return }
            self.request(segment, text: text, isFinal: false)
        }
    }

    private func language(_ language: Language) -> TranslationLanguage {
        TranslationLanguage(language: language, portugueseVariant: portugueseVariant)
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
}
