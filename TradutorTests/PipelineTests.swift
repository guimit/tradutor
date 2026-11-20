import Foundation
import Synchronization
import Testing
@testable import Tradutor

/// Fonte de áudio controlada pelo teste: entrega chunks e falha quando se pede.
@MainActor
final class FakeAudioSource: AudioSource {
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private(set) var stopError: Error?
    private(set) var isStopped = false
    let startError: Error?

    init(startError: Error? = nil) {
        self.startError = startError
    }

    func start() async throws -> AsyncStream<AudioChunk> {
        if let startError { throw startError }
        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        self.continuation = continuation
        return stream
    }

    func stop() async {
        isStopped = true
        continuation?.finish()
    }

    func send(at timestamp: TimeInterval) {
        continuation?.yield(AudioChunk(samples: [Float](repeating: 0.1, count: 160), timestamp: timestamp))
    }

    /// A captação cai sozinha (como o `SCStream` a chamar `didStopWithError`).
    func fail(with error: Error) {
        stopError = error
        continuation?.finish()
    }
}

/// Motor falso: regista os timestamps dos chunks que recebe e se o stream de áudio acabou.
@MainActor
final class RecordingTranscriptionEngine: TranscriptionEngine {
    final class Record: Sendable {
        let timestamps = Mutex<[TimeInterval]>([])
        let audioFinished = Mutex(false)
    }

    let metrics = TranscriptionMetrics()
    let record = Record()
    var timestamps: [TimeInterval] { record.timestamps.withLock { $0 } }
    var audioFinished: Bool { record.audioFinished.withLock { $0 } }

    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {}

    func transcribe(_ audio: AsyncStream<AudioChunk>) -> AsyncStream<TranscriptionEvent> {
        let (events, continuation) = AsyncStream.makeStream(of: TranscriptionEvent.self)
        let record = record
        let task = Task.detached {
            for await chunk in audio {
                record.timestamps.withLock { $0.append(chunk.timestamp) }
            }
            record.audioFinished.withLock { $0 = true }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return events
    }
}

private struct CaptureInterrupted: Error {}

@MainActor
private func waitUntil(timeout: Duration = .seconds(3), _ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while !condition(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor
final class CaptionPipelineRecoveryTests {
    let engine = RecordingTranscriptionEngine()
    var sources: [FakeAudioSource] = []
    /// Fontes criadas a partir desta, inclusive, falham ao arrancar.
    var failingStartsFrom = Int.max
    lazy var pipeline = CaptionPipeline(
        store: CaptionStore(),
        engines: TranscriptionEngineProvider { [engine] _ in engine },
        makeSource: { [unowned self] in
            let source = FakeAudioSource(startError: sources.count >= failingStartsFrom ? CaptureInterrupted() : nil)
            sources.append(source)
            return source
        },
        restartDelay: .milliseconds(10)
    )
    let settings: AppSettings

    init() {
        let name = "TradutorTests.\(UUID().uuidString)"
        settings = AppSettings(defaults: UserDefaults(suiteName: name)!)
        // Origem = destino: não há tradução (não depende dos idiomas instalados).
        settings.sourceLanguage = .fixed(.portuguese)
        settings.targetLanguage = .portuguese
    }

    @Test func interruptedCaptureResumesWithoutStoppingTranscription() async {
        await pipeline.start(settings: settings)
        sources[0].send(at: 0)
        await waitUntil { engine.timestamps.count == 1 }

        try? await Task.sleep(for: .milliseconds(30))
        sources[0].fail(with: CaptureInterrupted())
        await waitUntil { sources.count == 2 }
        sources[1].send(at: 0)
        await waitUntil { engine.timestamps.count == 2 }

        #expect(pipeline.status == .running)
        // A fonte nova recomeça em 0, mas o transcritor vê o tempo a continuar.
        let timestamps = engine.timestamps
        #expect(timestamps[1] > timestamps[0])
        #expect(!engine.audioFinished)
        await pipeline.stop()
    }

    @Test func permissionLossStopsCaptions() async {
        await pipeline.start(settings: settings)
        sources[0].fail(with: AudioSourceError.permissionDenied)
        await waitUntil { pipeline.status == .permissionMissing }
        #expect(pipeline.status == .permissionMissing)
        #expect(sources.count == 1)
    }

    @Test func givesUpAfterRepeatedFailures() async {
        failingStartsFrom = 1
        await pipeline.start(settings: settings)
        sources[0].fail(with: CaptureInterrupted())
        await waitUntil { if case .failed = pipeline.status { true } else { false } }
        guard case .failed = pipeline.status else {
            Issue.record("Esperava .failed, veio \(pipeline.status)")
            return
        }
        #expect(sources.count == 1 + CaptionPipeline.maxAudioRestarts)
    }

    @Test func restartAudioSwapsSourceImmediately() async {
        await pipeline.start(settings: settings)
        await pipeline.restartAudio()
        await waitUntil { sources.count == 2 }
        #expect(sources[0].isStopped)
        #expect(pipeline.status == .running)
        sources[1].send(at: 0)
        await waitUntil { engine.timestamps.count == 1 }
        #expect(engine.timestamps.count == 1)
        await pipeline.stop()
    }

    @Test func stopCancelsEverything() async {
        await pipeline.start(settings: settings)
        await pipeline.stop()
        #expect(pipeline.status == .idle)
        #expect(sources[0].isStopped)
        await waitUntil { engine.audioFinished }
        #expect(engine.audioFinished)
        #expect(sources.count == 1)
    }

    @Test func naturalEndOfSourceStopsWithoutError() async {
        await pipeline.start(settings: settings)
        await sources[0].stop()
        await waitUntil { pipeline.status == .idle }
        #expect(pipeline.status == .idle)
        #expect(sources.count == 1)
    }
}
