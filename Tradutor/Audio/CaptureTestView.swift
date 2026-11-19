import SwiftUI

/// Janela de debug para verificar a captação do áudio do sistema.
struct CaptureTestView: View {
    @State private var model = CaptureTestModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch model.state {
            case .permissionMissing:
                ScreenCapturePermissionWarning()
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Button("Tentar novamente") { Task { await model.start() } }
            case .idle, .starting, .capturing:
                meter
                recordingControls
            }
        }
        .padding(20)
        .frame(width: 420)
        .task { await model.start() }
        .onDisappear { Task { await model.stop() } }
    }

    private var meter: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.state == .capturing ? "Nível do áudio do sistema" : "A iniciar captação…")
                .font(.headline)
            LevelMeter(decibels: model.levelDecibels)
                .frame(height: 14)
            Text(model.levelDecibels > -100 ? String(format: "%.0f dBFS", model.levelDecibels) : "Silêncio")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var recordingControls: some View {
        switch model.recording {
        case .idle:
            Button("Gravar 10 s para o Desktop") { model.startRecording() }
                .disabled(model.state != .capturing)
        case .recording(let progress):
            ProgressView(value: progress) {
                Text("A gravar…")
            }
        case .saved(let url):
            VStack(alignment: .leading, spacing: 8) {
                Label("Gravado: \(url.lastPathComponent)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                HStack {
                    Button("Mostrar no Finder") { model.revealRecording() }
                    Button("Gravar outra vez") { model.startRecording() }
                }
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label("Erro ao gravar: \(message)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Button("Gravar outra vez") { model.startRecording() }
            }
        }
    }
}

struct ScreenCapturePermissionWarning: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Falta autorização para captar o áudio do sistema", systemImage: "lock.fill")
                .font(.headline)
            Text("""
                Em Definições do Sistema › Privacidade e Segurança › Gravação de Ecrã e Áudio do Sistema, \
                ativa o Tradutor. Depois, reinicia a app para a autorização ter efeito.
                """)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Abrir Definições do Sistema") { ScreenCapturePermission.openSystemSettings() }
                    .buttonStyle(.borderedProminent)
                Button("Reiniciar o Tradutor") { AppRelauncher.relaunch() }
            }
        }
    }
}

/// Barra horizontal de -60 dBFS (vazia) a 0 dBFS (cheia).
private struct LevelMeter: View {
    let decibels: Float

    private var fraction: CGFloat {
        CGFloat(min(max((decibels + 60) / 60, 0), 1))
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(LinearGradient(colors: [.green, .yellow, .red], startPoint: .leading, endPoint: .trailing))
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: geometry.size.width * fraction)
                    }
            }
        }
        .animation(.linear(duration: 0.05), value: fraction)
    }
}
