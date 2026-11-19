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
/// Chama-se `update()` depois de cada mudança no `CaptionStore`.
@MainActor
final class CaptionTranslator {
    struct Policy: Sendable {
        var minimumWords = 6
        var wordStep = 4
        var pauseDelay: Duration = .milliseconds(600)
        var minimumWordsOnPause = 3
    }

    /// Uma tradução que chegou: para as métricas de latência.
    struct Delivery: Sendable {
        var segmentID: CaptionSegment.ID
        var isFinal: Bool
        var fromCache: Bool
    }

    private struct Request {
        var task: Task<Void, Never>
        var text: String
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
    /// Segmentos cuja tradução final falhou: não se repete a cada evento.
    private var failed: Set<CaptionSegment.ID> = []
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
        failed.formIntersection(ids)

        for segment in store.segments where segment.needsTranslation {
            if segment.isConfirmed {
                guard !segment.isTranslationFinal, requests[segment.id]?.isFinal != true,
                      !failed.contains(segment.id)
                else { continue }
                request(segment, isFinal: true)
            } else {
                let words = Self.wordCount(segment.originalText)
                let previous = provisionalWordCount[segment.id]
                if words >= policy.minimumWords, previous.map({ words - $0 >= policy.wordStep }) ?? true {
                    request(segment, isFinal: false)
                }
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
        failed.removeAll()
    }

    // MARK: - Pedidos

    private func request(_ segment: CaptionSegment, isFinal: Bool) {
        let text = segment.originalText
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
            store.setTranslation(cached, for: id, isFinal: isFinal)
            onDelivery(Delivery(segmentID: id, isFinal: isFinal, fromCache: true))
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
            self?.complete(id: id, generation: generation, text: text, source: source, target: target, isFinal: isFinal, result: result)
        }
        requests[id] = Request(task: task, text: text, isFinal: isFinal, generation: generation)
    }

    private func complete(
        id: CaptionSegment.ID,
        generation: Int,
        text: String,
        source: TranslationLanguage,
        target: TranslationLanguage,
        isFinal: Bool,
        result: Result<String, Error>
    ) {
        // Só o pedido mais recente de cada segmento conta.
        guard requests[id]?.generation == generation else { return }
        requests[id] = nil
        switch result {
        case .success(let translation):
            cache.insert(translation, for: text, from: source, to: target)
            store.setTranslation(translation, for: id, isFinal: isFinal)
            onDelivery(Delivery(segmentID: id, isFinal: isFinal, fromCache: false))
        case .failure(let error):
            if isFinal { failed.insert(id) }
            onError(error)
        }
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
            self.request(segment, isFinal: false)
        }
    }

    private func language(_ language: Language) -> TranslationLanguage {
        TranslationLanguage(language: language, portugueseVariant: portugueseVariant)
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
}
