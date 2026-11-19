import AppKit
import SwiftUI

/// Gere o painel das legendas: posição, visibilidade, esconder após silêncio e modo de edição.
@MainActor
final class OverlayController {
    let model = OverlayModel()

    private let settings: AppSettings
    private let pipeline: CaptionPipeline
    private var panel: OverlayPanel?
    private var hideTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private var observers: [Task<Void, Never>] = []
    private var dragStart: (mouse: NSPoint, origin: NSPoint)?

    /// O que afeta o tamanho/posição do painel.
    private struct LayoutInputs: Equatable, Sendable {
        var mode: OverlayDisplayMode
        var translationAvailable: Bool
        var fontSize: Double
        var lineCount: Int
        var position: OverlayPosition
        var screenName: String?
    }

    init(settings: AppSettings, pipeline: CaptionPipeline) {
        self.settings = settings
        self.pipeline = pipeline

        observers.append(Task { [weak self, settings] in
            let inputs = Observations {
                LayoutInputs(
                    mode: settings.overlayDisplayMode,
                    translationAvailable: settings.isTranslationNeeded,
                    fontSize: settings.overlayFontSize,
                    lineCount: settings.overlayLineCount,
                    position: settings.overlayPosition,
                    screenName: settings.overlayScreenName
                )
            }
            for await _ in inputs { self?.relayout() }
        })
        observers.append(Task { [weak self, pipeline] in
            for await status in Observations({ pipeline.status }) { self?.statusChanged(status) }
        })
        observers.append(Task { [weak self, pipeline] in
            for await _ in Observations({ pipeline.store.revision }) { self?.captionsChanged() }
        })
        // Um aviso de tradução novo (ex.: idiomas por descarregar) mostra o painel.
        observers.append(Task { [weak self, pipeline] in
            for await issue in Observations({ pipeline.translationIssue }) {
                guard let self, issue != nil, pipeline.status == .running else { continue }
                self.showTemporarily(for: 8)
            }
        })
        // Monitor ligado/desligado ou resolução alterada.
        observers.append(Task { [weak self] in
            let changes = NotificationCenter.default
                .notifications(named: NSApplication.didChangeScreenParametersNotification)
                .map { _ in () }
            for await _ in changes { self?.relayout() }
        })
    }

    isolated deinit {
        observers.forEach { $0.cancel() }
        hideTask?.cancel()
        noticeTask?.cancel()
    }

    // MARK: - Modo de edição

    var isEditing: Bool { model.isEditing }

    /// No modo de edição o painel deixa de ser click-through para poder ser arrastado.
    func setEditing(_ editing: Bool) {
        guard editing != model.isEditing else { return }
        model.isEditing = editing
        if !editing, !pipeline.isActive { model.isShown = false }
        updatePanelVisibility()
    }

    func resetPosition() {
        settings.overlayScreenName = nil
        settings.overlayPosition = .default
    }

    /// Mostra um aviso curto no painel (também com as legendas paradas).
    func showNotice(_ text: String) {
        model.notice = text
        // Com as legendas a correr, o painel segue o ciclo normal (esconde-se após silêncio).
        if pipeline.isActive { showTemporarily() } else { model.isShown = true; updatePanelVisibility() }
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, let self else { return }
            self.model.notice = nil
            guard !self.pipeline.isActive else { return }
            self.model.isShown = false
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self.updatePanelVisibility()
        }
    }

    // MARK: - Estado do pipeline

    private func statusChanged(_ status: CaptionPipeline.Status) {
        switch status {
        case .idle:
            hideTask?.cancel()
            model.message = nil
            model.isShown = false
            // Deixa a animação de fade terminar antes de tirar o painel do ecrã.
            hideTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                self?.updatePanelVisibility()
            }
        case .preparing(let progress):
            hideTask?.cancel()
            model.message = progress.map { "A descarregar o modelo de transcrição… \(Int($0 * 100)) %" }
                ?? "A carregar o modelo de transcrição…"
            model.isShown = true
            updatePanelVisibility()
        case .running:
            model.message = "A ouvir…"
            showTemporarily()
        case .permissionMissing:
            model.message = "Falta a permissão de Gravação de Ecrã e Áudio do Sistema. Vê o menu do Tradutor."
            showTemporarily(for: 8)
        case .failed(let error):
            model.message = "Erro: \(error)"
            showTemporarily(for: 8)
        }
    }

    private func captionsChanged() {
        guard pipeline.status == .running, !pipeline.store.segments.isEmpty else { return }
        model.message = nil
        showTemporarily()
    }

    /// Mostra o painel e esconde-o depois de `seconds` sem atividade (silêncio).
    private func showTemporarily(for seconds: Double? = nil) {
        model.isShown = true
        updatePanelVisibility()

        let delay = seconds ?? settings.overlayHideDelay
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.model.isShown = false
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            // Depois do silêncio recomeça-se com o ecrã limpo, em vez de mostrar texto antigo.
            self.model.message = nil
            self.pipeline.clearCaptions()
            self.updatePanelVisibility()
        }
    }

    // MARK: - Painel

    private func updatePanelVisibility() {
        let needed = model.isEditing || model.isShown || pipeline.isActive
        guard needed else {
            panel?.orderOut(nil)
            return
        }
        let panel = panel ?? makePanel()
        panel.ignoresMouseEvents = !model.isEditing
        // `orderFrontRegardless`: a app nunca está ativa, e `orderFront` sozinho seria ignorado.
        panel.orderFrontRegardless()
    }

    private func makePanel() -> OverlayPanel {
        let panel = OverlayPanel()
        let view = OverlayView(
            model: model,
            pipeline: pipeline,
            settings: settings,
            onDragChanged: { [weak self] _ in self?.dragChanged() },
            onDragEnded: { [weak self] _ in self?.dragEnded() },
            onDone: { [weak self] in self?.setEditing(false) }
        )
        let hostingView = OverlayHostingView(rootView: view)
        // O tamanho do painel é decidido aqui (altura fixa), não pelo conteúdo SwiftUI.
        hostingView.sizingOptions = []
        hostingView.safeAreaRegions = []
        panel.contentView = hostingView
        self.panel = panel
        relayout()
        return panel
    }

    /// Monitor escolhido; se não estiver ligado (ou não houver escolha), o principal,
    /// que é o primeiro da lista (o da barra de menus), não `NSScreen.main` (o da janela ativa).
    private var targetScreen: NSScreen? {
        if let name = settings.overlayScreenName,
           let screen = NSScreen.screens.first(where: { $0.localizedName == name }) {
            return screen
        }
        return NSScreen.screens.first
    }

    private func relayout() {
        guard let screen = targetScreen else { return }
        let layout = OverlayLayout.make(
            mode: settings.overlayDisplayMode,
            translationAvailable: settings.isTranslationNeeded,
            fontSize: settings.overlayFontSize,
            lineCount: settings.overlayLineCount,
            screenWidth: screen.visibleFrame.width
        )
        model.layout = layout
        guard let panel, dragStart == nil else { return }
        let frame = OverlayLayout.frame(size: layout.size, position: settings.overlayPosition, in: screen.visibleFrame)
        panel.setFrame(frame, display: true)
    }

    // MARK: - Arrastar

    // Usa-se a posição global do rato (e não a translação do gesto), porque as coordenadas
    // do gesto são relativas ao painel, que se está a mover.
    private func dragChanged() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let start = dragStart ?? (mouse, panel.frame.origin)
        dragStart = start
        panel.setFrameOrigin(NSPoint(x: start.origin.x + mouse.x - start.mouse.x, y: start.origin.y + mouse.y - start.mouse.y))
    }

    private func dragEnded() {
        dragStart = nil
        guard let panel else { return }
        let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? targetScreen else { return }
        // Largar noutro monitor passa a ser a escolha de monitor.
        settings.overlayScreenName = screen == NSScreen.screens.first ? nil : screen.localizedName
        settings.overlayPosition = OverlayLayout.position(of: panel.frame, in: screen.visibleFrame)
        relayout()
    }
}
