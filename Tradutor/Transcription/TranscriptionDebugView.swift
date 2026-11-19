import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Janela de debug: mostra os eventos de transcrição em tempo real
/// (parcial a cinzento, finais a preto) e a latência medida.
struct TranscriptionDebugView: View {
    @Bindable var settings: AppSettings
    @State private var model: TranscriptionDebugModel

    init(settings: AppSettings, engines: TranscriptionEngineProvider) {
        self.settings = settings
        _model = State(initialValue: TranscriptionDebugModel(engines: engines))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            controls
                .padding(16)
            Divider()
            status
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            Divider()
            transcript
        }
        .frame(minWidth: 560, minHeight: 420)
        .onDisappear { Task { await model.stop() } }
    }

    // MARK: - Controlos

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                Picker("Motor", selection: $settings.transcriptionEngine) {
                    ForEach(TranscriptionEngineKind.allCases) { Text($0.displayName).tag($0) }
                }
                if settings.transcriptionEngine == .whisperKit {
                    Picker("Modelo", selection: $settings.whisperModel) {
                        ForEach(WhisperModel.allCases) { model in
                            Text(model.displayName + (WhisperModelStore.isDownloaded(model) ? "" : " — por descarregar"))
                                .tag(model)
                        }
                    }
                }
                Picker("Idioma de origem", selection: $settings.sourceLanguage) {
                    ForEach(SourceLanguage.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Picker("Variante do português", selection: $settings.portugueseVariant) {
                    ForEach(PortugueseVariant.allCases) { Text($0.displayName).tag($0) }
                }
            }
            .disabled(model.isActive)

            HStack {
                if model.isActive {
                    Button("Parar") { Task { await model.stop() } }
                        .keyboardShortcut(.cancelAction)
                } else {
                    Button("Transcrever áudio do sistema") {
                        Task { await model.start(settings: settings) }
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Transcrever ficheiro…") { chooseFile() }
                }
                Spacer()
                Button("Limpar") { model.clear() }
                    .disabled(model.finals.isEmpty && model.partial == nil)
            }
        }
    }

    // MARK: - Estado e latência

    @ViewBuilder
    private var status: some View {
        switch model.phase {
        case .idle:
            Text("Parado").foregroundStyle(.secondary)
        case .downloading(let progress):
            ProgressView(value: progress) {
                Text("A descarregar o modelo… \(Int(progress * 100)) %")
            }
        case .loading:
            HStack {
                ProgressView().controlSize(.small)
                Text("A carregar o modelo (na primeira vez pode demorar 1–2 minutos)…")
            }
        case .running:
            HStack(spacing: 16) {
                Label(model.sourceDescription, systemImage: "waveform")
                if let language = model.partial?.language ?? model.finals.last?.language {
                    Text("Idioma: \(language.displayName)")
                }
                Spacer()
                Text(latencyDescription)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        case .permissionMissing:
            ScreenCapturePermissionWarning()
                .padding(.vertical, 8)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }

    private var latencyDescription: String {
        let metrics = model.metrics
        var parts: [String] = []
        if let inference = metrics.lastInference {
            parts.append(String(format: "inferência %.0f ms (média %.0f ms)", inference * 1000, (metrics.averageInference ?? inference) * 1000))
        }
        if let rtf = metrics.realTimeFactor {
            parts.append(String(format: "RTF %.2f", rtf))
        }
        if let delay = metrics.lastEventDelay {
            parts.append(String(format: "atraso %.0f ms", delay * 1000))
        }
        return parts.isEmpty ? "A ouvir…" : parts.joined(separator: " · ")
    }

    // MARK: - Transcrição

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(model.finals) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(line.language.rawValue) \(Self.format(line.start))–\(Self.format(line.end))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                            Text(line.text)
                                .foregroundStyle(.primary)
                        }
                    }
                    if let partial = model.partial {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(partial.language.rawValue) …")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                            Text(partial.text)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .textSelection(.enabled)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: model.finals.count) { proxy.scrollTo("bottom") }
            .onChange(of: model.partial?.text) { proxy.scrollTo("bottom") }
        }
    }

    private static func format(_ time: TimeInterval) -> String {
        String(format: "%d:%04.1f", Int(time) / 60, time.truncatingRemainder(dividingBy: 60))
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.message = "Escolhe um ficheiro de áudio para transcrever ao ritmo real."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.start(settings: settings, fileURL: url) }
    }
}
