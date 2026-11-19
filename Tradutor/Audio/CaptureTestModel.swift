import AppKit
import Foundation
import Observation

/// Lógica da janela de debug "Testar captação": medidor de nível e gravação de 10 s para WAV.
@MainActor
@Observable
final class CaptureTestModel {
    enum State: Equatable {
        case idle
        case starting
        case permissionMissing
        case capturing
        case failed(String)
    }

    enum RecordingState: Equatable {
        case idle
        case recording(progress: Double)
        case saved(URL)
        case failed(String)
    }

    static let recordingDuration: TimeInterval = 10

    private(set) var state: State = .idle
    private(set) var recording: RecordingState = .idle
    /// Nível suavizado em dBFS, para o medidor.
    private(set) var levelDecibels: Float = -160

    private let source = SystemAudioSource()
    private var captureTask: Task<Void, Never>?
    private var writer: WAVFileWriter?
    private var writerURL: URL?

    func start() async {
        guard state != .capturing, state != .starting else { return }

        if !ScreenCapturePermission.isGranted {
            // Mostra o pedido do sistema na primeira vez e põe a app na lista das Definições.
            ScreenCapturePermission.request()
            state = .permissionMissing
            return
        }

        state = .starting
        do {
            let chunks = try await source.start()
            state = .capturing
            captureTask = Task { [weak self] in
                for await chunk in chunks {
                    self?.handle(chunk)
                }
                self?.captureDidEnd()
            }
        } catch AudioSourceError.permissionDenied {
            state = .permissionMissing
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func stop() async {
        captureTask?.cancel()
        captureTask = nil
        await source.stop()
        finishRecording()
        levelDecibels = -160
        if state == .capturing || state == .starting { state = .idle }
    }

    func startRecording() {
        guard state == .capturing else { return }
        if case .recording = recording { return }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'às' HH.mm.ss"
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let url = desktop.appendingPathComponent("Tradutor teste \(formatter.string(from: .now)).wav")

        do {
            writer = try WAVFileWriter(url: url)
            writerURL = url
            recording = .recording(progress: 0)
        } catch {
            recording = .failed(error.localizedDescription)
        }
    }

    func revealRecording() {
        if case .saved(let url) = recording {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private func handle(_ chunk: AudioChunk) {
        // Sobe logo, desce devagar — como um medidor de picos.
        let decibels = chunk.rmsDecibels
        levelDecibels = decibels > levelDecibels ? decibels : max(decibels, levelDecibels - 1.5)

        guard let writer else { return }
        let target = Int(Self.recordingDuration * AudioChunk.sampleRate)
        let remaining = target - writer.framesWritten
        do {
            try writer.write(Array(chunk.samples.prefix(remaining)))
        } catch {
            recording = .failed(error.localizedDescription)
            self.writer = nil
            return
        }
        recording = .recording(progress: Double(writer.framesWritten) / Double(target))
        if writer.framesWritten >= target {
            finishRecording()
        }
    }

    private func finishRecording() {
        guard let writer, let writerURL else { return }
        writer.close()
        self.writer = nil
        self.writerURL = nil
        recording = .saved(writerURL)
    }

    private func captureDidEnd() {
        finishRecording()
        levelDecibels = -160
        guard state == .capturing else { return }
        switch source.stopError {
        case AudioSourceError.permissionDenied?:
            state = .permissionMissing
        case let error?:
            state = .failed(error.localizedDescription)
        case nil:
            state = .idle
        }
    }
}
