import Carbon.HIToolbox
import Foundation
import Testing
@testable import Tradutor

@MainActor
struct SettingsPersistenceTests {
    private func makeDefaults() -> UserDefaults {
        let name = "TradutorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func hotKeysStartWithDefaults() {
        let settings = AppSettings(defaults: makeDefaults())
        #expect(settings.toggleCaptionsHotKey == .defaultToggleCaptions)
        #expect(settings.cycleDisplayModeHotKey == .defaultCycleDisplayMode)
    }

    @Test func customAndRemovedHotKeysArePersisted() {
        let defaults = makeDefaults()
        let custom = HotKey(keyCode: UInt32(kVK_F5), modifiers: 0, key: "F5")
        do {
            let settings = AppSettings(defaults: defaults)
            settings.toggleCaptionsHotKey = custom
            settings.cycleDisplayModeHotKey = nil
        }
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.toggleCaptionsHotKey == custom)
        // Removido não volta ao atalho por defeito.
        #expect(reloaded.cycleDisplayModeHotKey == nil)
    }

    @Test func otherSettingsArePersisted() {
        let defaults = makeDefaults()
        do {
            let settings = AppSettings(defaults: defaults)
            settings.sourceLanguage = .fixed(.english)
            settings.targetLanguage = .spanish
            settings.portugueseVariant = .brazil
            settings.overlayDisplayMode = .translation
            settings.overlayFontSize = 40
            settings.showLatency = true
            settings.silenceWarningDelay = 60
        }
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.sourceLanguage == .fixed(.english))
        #expect(reloaded.targetLanguage == .spanish)
        #expect(reloaded.portugueseVariant == .brazil)
        #expect(reloaded.overlayDisplayMode == .translation)
        #expect(reloaded.overlayFontSize == 40)
        #expect(reloaded.showLatency)
        #expect(reloaded.silenceWarningDelay == 60)
    }
}

struct HotKeyTests {
    @Test func displayStringFollowsMacOrder() {
        let hotKey = HotKey(keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(cmdKey | shiftKey | optionKey | controlKey), key: "L")
        #expect(hotKey.displayString == "⌃⌥⇧⌘L")
        #expect(HotKey.defaultToggleCaptions.displayString == "⌃⌥L")
    }

    @Test func displayModeCyclesThroughAll() {
        var mode = OverlayDisplayMode.original
        var seen: [OverlayDisplayMode] = []
        for _ in 0..<3 {
            mode = mode.next
            seen.append(mode)
        }
        #expect(seen == [.translation, .both, .original])
    }
}

struct AudioClockTests {
    @Test func onlyAudibleChunksCountAsSound() async throws {
        let clock = AudioClock()
        let start = clock.lastSound
        try await Task.sleep(for: .milliseconds(20))
        clock.observe(AudioChunk(samples: Array(repeating: 0, count: 1600), timestamp: 0))
        #expect(clock.lastSound == start)
        clock.observe(AudioChunk(samples: (0..<1600).map { sin(Float($0) * 0.1) * 0.1 }, timestamp: 0.1))
        #expect(clock.lastSound > start)
    }
}
