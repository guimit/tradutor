import SwiftUI

/// Estado que o `OverlayController` passa à vista.
@MainActor
@Observable
final class OverlayModel {
    var layout = OverlayLayout(blocks: [], width: 600)
    /// `false` depois de alguns segundos de silêncio (o texto desaparece com fade).
    var isShown = false
    var isEditing = false
    /// Mensagem de estado (a carregar o modelo, erros…), mostrada em vez das legendas.
    var message: String?
    /// Aviso curto por cima das legendas (ex.: o modo mudou pelo atalho de teclado).
    var notice: String?
}

struct OverlayView: View {
    let model: OverlayModel
    let pipeline: CaptionPipeline
    let settings: AppSettings
    var onDragChanged: (DragGesture.Value) -> Void = { _ in }
    var onDragEnded: (DragGesture.Value) -> Void = { _ in }
    var onDone: () -> Void = {}

    /// "Aumentar contraste" (Acessibilidade › Ecrã): fundo quase opaco, como pedem as normas
    /// de legendagem, seja qual for a opacidade escolhida.
    @Environment(\.colorSchemeContrast) private var contrast

    private var backgroundOpacity: Double {
        contrast == .increased ? max(settings.overlayBackgroundOpacity, 0.9) : settings.overlayBackgroundOpacity
    }

    var body: some View {
        let layout = model.layout
        VStack(spacing: OverlayLayout.blockSpacing) {
            ForEach(layout.blocks) { block in
                CaptionBlockView(
                    runs: runs(for: block.kind),
                    block: block,
                    width: layout.contentWidth,
                    isSecondary: layout.blocks.count > 1 && block.kind == .original
                )
            }
        }
        .padding(.horizontal, OverlayLayout.horizontalPadding)
        .padding(.vertical, OverlayLayout.verticalPadding)
        .frame(width: layout.width, height: layout.height)
        .background {
            RoundedRectangle(cornerRadius: OverlayLayout.cornerRadius, style: .continuous)
                .fill(.black.opacity(backgroundOpacity))
        }
        .overlay {
            if model.isEditing {
                RoundedRectangle(cornerRadius: OverlayLayout.cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.9), style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
            }
        }
        .overlay(alignment: .topTrailing) {
            if model.isEditing {
                Button("Concluído", action: onDone)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(6)
            }
        }
        .overlay(alignment: .topLeading) {
            // Modo debug: latência fala → original → tradução, na margem de cima.
            if settings.showLatency, !model.isEditing {
                Text(latencyDescription)
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.leading, OverlayLayout.horizontalPadding)
                    .padding(.top, 1)
            }
        }
        .overlay(alignment: .topTrailing) {
            if let issue = pipeline.translationIssue, !model.isEditing {
                Label(issue, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.yellow)
                    .lineLimit(1)
                    .padding(.trailing, OverlayLayout.horizontalPadding)
                    .padding(.top, 1)
            }
        }
        .overlay(alignment: .top) {
            // Na margem de cima, para não tapar as legendas.
            if let notice = model.notice, !model.isEditing {
                Text(notice)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.top, 1)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.notice)
        .contentShape(Rectangle())
        .gesture(
            // Coordenadas globais: as locais mudariam enquanto o próprio painel se move.
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged(onDragChanged)
                .onEnded(onDragEnded),
            isEnabled: model.isEditing
        )
        .opacity(model.isShown || model.isEditing ? 1 : 0)
        .animation(.easeInOut(duration: 0.4), value: model.isShown || model.isEditing)
    }

    private func runs(for kind: OverlayLayout.BlockKind) -> [CaptionRun] {
        if model.isEditing {
            return [CaptionRun(
                id: Self.placeholderID,
                text: "As legendas aparecem aqui. Arrasta esta caixa para a mudar de sítio.",
                isConfirmed: true
            )]
        }
        let segments = pipeline.store.segments
        if let message = model.message, segments.isEmpty {
            return kind == model.layout.blocks.last?.kind
                ? [CaptionRun(id: Self.placeholderID, text: message, isConfirmed: false)]
                : []
        }
        let showsBoth = model.layout.blocks.count > 1
        return segments.compactMap { segment in
            switch kind {
            case .original:
                // Com os dois blocos, o que já está no idioma de destino aparece só no de baixo.
                if showsBoth, !segment.needsTranslation { return nil }
                return CaptionRun(id: segment.id, text: segment.originalText, isConfirmed: segment.isConfirmed)
            case .translation:
                if !segment.needsTranslation {
                    return CaptionRun(id: segment.id, text: segment.originalText, isConfirmed: segment.isConfirmed)
                }
                // Já faz parte da tradução de um segmento anterior (frase partida pelo motor).
                if segment.isTranslationMerged { return nil }
                if let translation = segment.translatedText {
                    // Provisória a cinzento; a final, a branco, substitui-a no mesmo sítio.
                    return CaptionRun(id: segment.id, text: translation, isConfirmed: segment.isTranslationFinal)
                }
                // "Só tradução": enquanto a tradução não chega, mostra-se o original a cinzento
                // (o utilizador vê logo que há fala). Com os dois blocos, o original já está em cima.
                return showsBoth ? nil : CaptionRun(id: segment.id, text: segment.originalText, isConfirmed: false)
            }
        }
    }

    private var latencyDescription: String {
        let latency = pipeline.latency
        func format(_ stat: CaptionLatency.Stat) -> String {
            guard let last = stat.last, let average = stat.average else { return "—" }
            return "\(Int(last * 1000)) ms (média \(Int(average * 1000)))"
        }
        return "fala→original \(format(latency.speechToOriginal)) · "
            + "original→tradução \(format(latency.originalToTranslation)) · "
            + "fala→tradução \(format(latency.speechToTranslation))"
    }

    private static let placeholderID = UUID()
}

/// Um bloco de texto com altura fixa de N linhas, alinhado em baixo.
/// Mostra as últimas N linhas; quando uma linha nova aparece, as outras sobem com animação.
private struct CaptionBlockView: View {
    let runs: [CaptionRun]
    let block: OverlayLayout.Block
    let width: CGFloat
    let isSecondary: Bool

    /// Reduzir movimento: as linhas aparecem e desaparecem sem deslizar.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        // Uma pequena margem: a soma das larguras das palavras ignora o kerning entre elas.
        let lines = CaptionLineBreaker
            .lines(for: runs, maxWidth: width - 4, font: OverlayLayout.font(size: block.fontSize))
            .suffix(block.lineCount)

        VStack(alignment: .leading, spacing: 0) {
            ForEach(lines) { line in
                Text(attributed(line))
                    .font(.system(size: block.fontSize, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    // Parcial → final: as letras transformam-se em vez de se sobreporem.
                    .contentTransition(reduceMotion ? .identity : .interpolate)
                    .frame(maxWidth: .infinity, minHeight: block.lineHeight, maxHeight: block.lineHeight, alignment: .leading)
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .move(edge: .top).combined(with: .opacity)
                    ))
            }
        }
        .frame(width: width, height: block.height, alignment: .bottom)
        .clipped()
        .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: lines.map(\.id))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: lines.map(\.words))
    }

    /// Final a branco; parcial a cinzento claro. Como o final mantém o id do parcial que
    /// substitui, a troca acontece no mesmo sítio (só muda a cor e, por vezes, uma palavra).
    ///
    /// Contraste: com o fundo por defeito (preto a 70 %) sobre uma página branca, o fundo
    /// efetivo fica cinzento-escuro; o cinzento do parcial (0,75) ainda dá ~4,6:1 (WCAG AA).
    private func attributed(_ line: CaptionLine) -> AttributedString {
        let increased = contrast == .increased
        let confirmed: Color = isSecondary && !increased ? Color(white: 0.88) : .white
        let partial = Color(white: increased ? 0.85 : 0.75)
        var result = AttributedString()
        for (index, word) in line.words.enumerated() {
            var piece = AttributedString(index == 0 ? word.text : " " + word.text)
            piece.foregroundColor = word.isConfirmed ? confirmed : partial
            result += piece
        }
        return result
    }
}
