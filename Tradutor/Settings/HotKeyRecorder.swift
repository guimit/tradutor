import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Campo para gravar um atalho global: clica-se e prime-se a combinação.
/// Esc cancela; o botão ✕ remove o atalho.
struct HotKeyRecorder: View {
    @Binding var hotKey: HotKey?
    let hotKeys: GlobalHotKeys

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var rejected = false

    var body: some View {
        HStack(spacing: 4) {
            Button {
                isRecording ? stopRecording() : startRecording()
            } label: {
                Text(label)
                    .frame(minWidth: 110)
                    .foregroundStyle(isRecording ? Color.accentColor : .primary)
            }
            .help(isRecording ? "Prime a combinação (Esc cancela)" : "Clica para gravar outro atalho")

            if hotKey != nil, !isRecording {
                Button {
                    hotKey = nil
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Remover atalho")
            }
        }
        .onDisappear { stopRecording() }
    }

    private var label: String {
        if isRecording { return rejected ? "Usa ⌃, ⌥ ou ⌘…" : "Prime o atalho…" }
        return hotKey?.displayString ?? "Nenhum"
    }

    private func startRecording() {
        isRecording = true
        rejected = false
        hotKeys.isSuspended = true
        // Monitor local: a janela de Definições está ativa enquanto se grava.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                if event.keyCode == UInt16(kVK_Escape) {
                    stopRecording()
                } else if let newHotKey = HotKey(event: event) {
                    hotKey = newHotKey
                    stopRecording()
                } else {
                    rejected = true
                    NSSound.beep()
                }
            }
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if isRecording { hotKeys.isSuspended = false }
        isRecording = false
    }
}
