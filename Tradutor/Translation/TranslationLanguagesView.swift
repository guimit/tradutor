import SwiftUI
import Translation

/// Estado dos pares de idiomas da tradução da Apple, com download dos que faltam.
///
/// O download só pode ser pedido por uma `TranslationSession` vinda do `.translationTask`:
/// `prepareTranslation()` mostra um pedido do sistema ligado a esta janela ("Descarregar
/// idiomas?"), e o macOS faz o download em segundo plano. A API não dá a percentagem do
/// download, por isso mostramos um indicador indeterminado e vamos consultando o estado.
struct TranslationLanguagesView: View {
    let portugueseVariant: PortugueseVariant

    @State private var statuses: [Pair: TranslationPairStatus] = [:]
    @State private var downloading: Pair?
    @State private var configuration: TranslationSession.Configuration?
    @State private var error: String?

    struct Pair: Hashable, Identifiable {
        var source: TranslationLanguage
        var target: TranslationLanguage
        var id: String { "\(source.identifier)>\(target.identifier)" }
    }

    private var pairs: [Pair] {
        let languages = Language.allCases.map { TranslationLanguage(language: $0, portugueseVariant: portugueseVariant) }
        return languages.flatMap { source in
            languages.filter { $0 != source }.map { Pair(source: source, target: $0) }
        }
    }

    var body: some View {
        Section {
            ForEach(pairs) { pair in
                HStack {
                    Text("\(pair.source.displayName) → \(pair.target.displayName)")
                    Spacer()
                    statusView(for: pair)
                }
            }
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Idiomas no dispositivo")
        } footer: {
            Text("Os idiomas também se gerem em Definições do Sistema › Geral › Idioma e Região › Idiomas da tradução.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task(id: portugueseVariant) { await refresh() }
        .translationTask(configuration) { session in
            guard let pair = downloading else { return }
            do {
                // Mostra o pedido do sistema; termina quando o utilizador aceita e o download
                // acaba, ou com erro se o utilizador cancelar.
                try await UncheckedSession(session: session).prepare()
                error = nil
            } catch {
                self.error = "Download de \(pair.source.displayName) → \(pair.target.displayName) cancelado ou falhado."
            }
            downloading = nil
            await refresh()
        }
        .task(id: downloading) {
            // Enquanto o download decorre, consulta o estado (a API não reporta progresso).
            while downloading != nil, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await refresh()
            }
        }
    }

    @ViewBuilder
    private func statusView(for pair: Pair) -> some View {
        if downloading == pair {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("A descarregar…").foregroundStyle(.secondary)
            }
        } else {
            switch statuses[pair] {
            case .ready?:
                Label("Instalado", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .needsDownload?:
                Button("Descarregar") { download(pair) }
                    .disabled(downloading != nil)
            case .unsupported?:
                Text("Não suportado").foregroundStyle(.secondary)
            case nil:
                ProgressView().controlSize(.small)
            }
        }
    }

    private func download(_ pair: Pair) {
        downloading = pair
        let source = Locale.Language(identifier: pair.source.identifier)
        let target = Locale.Language(identifier: pair.target.identifier)
        if configuration?.source == source, configuration?.target == target {
            // Mesma configuração: `invalidate()` volta a correr a ação do `.translationTask`.
            configuration?.invalidate()
        } else {
            configuration = TranslationSession.Configuration(source: source, target: target)
        }
    }

    private func refresh() async {
        let engine = AppleTranslationEngine()
        for pair in pairs {
            statuses[pair] = await engine.status(from: pair.source, to: pair.target)
        }
    }
}

/// A `TranslationSession` não é Sendable, e a ação do `.translationTask` corre no main actor;
/// chamar o método async (não isolado) diretamente "envia" a sessão para fora do main actor.
/// A sessão é usada só aqui e só por esta chamada, por isso é seguro.
private struct UncheckedSession: @unchecked Sendable {
    let session: TranslationSession

    nonisolated func prepare() async throws {
        try await session.prepareTranslation()
    }
}
