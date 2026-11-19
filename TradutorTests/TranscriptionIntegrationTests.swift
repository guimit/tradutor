import Foundation
import Testing
@testable import Tradutor

/// Testes com os motores reais e fala sintetizada pelo `say`.
/// Descarregam modelos, por isso só correm quando pedidos:
///
///     TEST_RUNNER_TRADUTOR_INTEGRATION=1 TEST_RUNNER_TRADUTOR_WHISPER_MODEL=small \
///       xcodebuild -project Tradutor.xcodeproj -scheme Tradutor -derivedDataPath build test \
///       -only-testing:TradutorTests/TranscriptionIntegrationTests
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["TRADUTOR_INTEGRATION"] != nil), .serialized)
struct TranscriptionIntegrationTests {
    struct Sample: Sendable, CustomTestStringConvertible {
        let voice: String
        let language: Language
        let variant: PortugueseVariant
        let text: String
        /// Palavras que têm de aparecer na transcrição.
        let keywords: [String]

        var testDescription: String { "\(voice) (\(language.rawValue))" }
    }

    nonisolated static let samples: [Sample] = [
        Sample(
            voice: "Joana", language: .portuguese, variant: .portugal,
            text: "Bom dia a todos. Hoje vamos falar sobre o novo projeto e sobre o calendário das próximas semanas. Está tudo pronto para começarmos?",
            keywords: ["projeto", "calendário", "semanas"]
        ),
        Sample(
            voice: "Luciana", language: .portuguese, variant: .brazil,
            text: "Bom dia, pessoal. Hoje a gente vai conversar sobre o novo projeto e sobre o cronograma das próximas semanas. Está tudo pronto para começar?",
            keywords: ["projeto", "cronograma", "semanas"]
        ),
        Sample(
            voice: "Samantha", language: .english, variant: .portugal,
            text: "Good morning everyone. Today we are going to talk about the new project and the schedule for the next few weeks. Is everything ready to start?",
            keywords: ["project", "schedule", "weeks"]
        ),
        Sample(
            voice: "Eddy (Spanish (Spain))", language: .spanish, variant: .portugal,
            text: "Buenos días a todos. Hoy vamos a hablar del nuevo proyecto y del calendario de las próximas semanas. ¿Está todo listo para empezar?",
            keywords: ["proyecto", "calendario", "semanas"]
        ),
    ]

    static var whisperModel: WhisperModel {
        switch ProcessInfo.processInfo.environment["TRADUTOR_WHISPER_MODEL"] {
        case "small": .small
        case "large": .largeTurbo
        default: .base
        }
    }

    @Test(arguments: samples)
    func whisperKitAutoDetectsAndTranscribes(_ sample: Sample) async throws {
        let audio = try synthesize(sample.text, voice: sample.voice)
        let engine = WhisperKitEngine(
            configuration: TranscriptionConfiguration(sourceLanguage: .auto, portugueseVariant: sample.variant),
            model: Self.whisperModel
        )
        try await engine.prepare { _ in }

        let events = try await transcribe(audio, with: engine)
        report("WhisperKit \(Self.whisperModel.rawValue) · \(sample.testDescription)", events, engine.metrics.snapshot)

        let finals = finalTexts(events)
        #expect(finals.allSatisfy { $0.language == sample.language })
        let text = finals.map(\.text).joined(separator: " ").lowercased()
        for keyword in sample.keywords {
            #expect(text.contains(keyword), "falta \"\(keyword)\" em: \(text)")
        }
    }

    @Test func whisperKitSwitchesLanguageMidStream() async throws {
        let english = try FileAudioSource.loadSamples(from: synthesize(Self.samples[2].text, voice: "Samantha"))
        let portuguese = try FileAudioSource.loadSamples(from: synthesize(Self.samples[0].text, voice: "Joana"))
        let silence = [Float](repeating: 0, count: Int(1.5 * AudioChunk.sampleRate))
        let url = try writeWAV(english + silence + portuguese + silence + english)

        let engine = WhisperKitEngine(
            configuration: TranscriptionConfiguration(sourceLanguage: .auto, portugueseVariant: .portugal),
            model: Self.whisperModel
        )
        try await engine.prepare { _ in }
        let events = try await transcribe(url, with: engine)
        report("WhisperKit \(Self.whisperModel.rawValue) · en → pt → en", events, engine.metrics.snapshot)

        let languages = finalTexts(events).map(\.language)
        #expect(languages.first == .english)
        #expect(languages.contains(.portuguese))
        #expect(languages.last == .english)
    }

    @Test(arguments: samples)
    func appleSpeechTranscribes(_ sample: Sample) async throws {
        let audio = try synthesize(sample.text, voice: sample.voice)
        let engine = AppleSpeechEngine(
            configuration: TranscriptionConfiguration(sourceLanguage: .fixed(sample.language), portugueseVariant: sample.variant)
        )
        try await engine.prepare { _ in }

        // Ao ritmo real, para a latência medida ser a de uso ao vivo.
        let events = try await transcribe(audio, with: engine, realTime: true)
        report("Apple SpeechAnalyzer · \(sample.testDescription)", events, engine.metrics.snapshot)

        let text = finalTexts(events).map(\.text).joined(separator: " ").lowercased()
        for keyword in sample.keywords {
            #expect(text.contains(keyword), "falta \"\(keyword)\" em: \(text)")
        }
    }

    // MARK: - Auxiliares

    private func transcribe(_ url: URL, with engine: any TranscriptionEngine, realTime: Bool = false) async throws -> [TranscriptionEvent] {
        let source = FileAudioSource(url: url, realTime: realTime)
        var events: [TranscriptionEvent] = []
        for await event in engine.transcribe(try await source.start()) {
            events.append(event)
        }
        return events
    }

    private func finalTexts(_ events: [TranscriptionEvent]) -> [(text: String, language: Language)] {
        events.compactMap {
            if case .final(let text, let language, _, _) = $0 { return (text, language) }
            return nil
        }
    }

    private func report(_ title: String, _ events: [TranscriptionEvent], _ metrics: TranscriptionMetrics.Snapshot) {
        var lines = ["", "=== \(title)"]
        for event in events {
            switch event {
            case .partial(let text, let language): lines.append("  … [\(language.rawValue)] \(text)")
            case .final(let text, let language, let start, let end):
                lines.append(String(format: "  ✓ [%@] %5.1f–%5.1f  %@", language.rawValue, start, end, text))
            }
        }
        lines.append(String(
            format: "  passagens: %d · última inferência: %.0f ms · média: %.0f ms · RTF: %.2f · último atraso: %.0f ms",
            metrics.passCount,
            (metrics.lastInference ?? 0) * 1000,
            (metrics.averageInference ?? 0) * 1000,
            metrics.realTimeFactor ?? 0,
            (metrics.lastEventDelay ?? 0) * 1000
        ))
        print(lines.joined(separator: "\n"))
    }

    private func synthesize(_ text: String, voice: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "tradutor-\(UUID().uuidString).aiff")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", voice, "-o", url.path, text]
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        return url
    }

    private func writeWAV(_ samples: [Float]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "tradutor-\(UUID().uuidString).wav")
        let writer = try WAVFileWriter(url: url)
        try writer.write(samples)
        writer.close()
        return url
    }
}
