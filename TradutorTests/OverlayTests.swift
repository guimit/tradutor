import AppKit
import Foundation
import Testing
@testable import Tradutor

// MARK: - Legendas (CaptionStore)

@MainActor
struct CaptionStoreTests {
    @Test func partialsUpdateTheSameSegment() {
        let store = CaptionStore()
        store.apply(.partial(text: "Bom", language: .portuguese), targetLanguage: .english)
        store.apply(.partial(text: "Bom dia a", language: .portuguese), targetLanguage: .english)
        #expect(store.segments.count == 1)
        #expect(store.segments[0].originalText == "Bom dia a")
        #expect(!store.segments[0].isConfirmed)
    }

    @Test func finalReplacesPartialInPlace() {
        let store = CaptionStore()
        store.apply(.partial(text: "Bom dia a", language: .portuguese), targetLanguage: .english)
        let id = store.segments[0].id
        store.apply(.final(text: "Bom dia a todos.", language: .portuguese, start: 0, end: 2), targetLanguage: .english)
        #expect(store.segments.count == 1)
        #expect(store.segments[0].id == id)
        #expect(store.segments[0].originalText == "Bom dia a todos.")
        #expect(store.segments[0].isConfirmed)
        #expect(store.segments[0].targetLanguage == .english)
    }

    @Test func partialAfterFinalStartsNewSegment() {
        let store = CaptionStore()
        store.apply(.final(text: "Olá.", language: .portuguese, start: 0, end: 1), targetLanguage: .english)
        store.apply(.partial(text: "Tudo", language: .portuguese), targetLanguage: .english)
        store.apply(.final(text: "Tudo bem?", language: .portuguese, start: 1, end: 2), targetLanguage: .english)
        #expect(store.segments.map(\.originalText) == ["Olá.", "Tudo bem?"])
        #expect(store.segments.allSatisfy { $0.isConfirmed })
    }

    @Test func emptyFinalRemovesPartial() {
        let store = CaptionStore()
        store.apply(.partial(text: "hmm", language: .english), targetLanguage: .portuguese)
        store.apply(.final(text: "  ", language: .english, start: 0, end: 1), targetLanguage: .portuguese)
        #expect(store.segments.isEmpty)
    }

    @Test func trimsHalfWhenOverLimit() {
        let store = CaptionStore(maxSegments: 4)
        for index in 0..<5 {
            store.apply(.final(text: "s\(index)", language: .english, start: Double(index), end: Double(index) + 1), targetLanguage: .portuguese)
        }
        #expect(store.segments.map(\.originalText) == ["s3", "s4"])
    }

    @Test func translationIsStoredBySegment() {
        let store = CaptionStore()
        store.apply(.final(text: "Hello.", language: .english, start: 0, end: 1), targetLanguage: .portuguese)
        store.setTranslation("Olá.", for: store.segments[0].id, isFinal: true)
        #expect(store.segments[0].translatedText == "Olá.")
    }

    @Test func revisionChangesOnEveryEvent() {
        let store = CaptionStore()
        store.apply(.partial(text: "a", language: .english), targetLanguage: .portuguese)
        store.apply(.partial(text: "a b", language: .english), targetLanguage: .portuguese)
        #expect(store.revision == 2)
    }
}

// MARK: - Quebra de linhas

struct CaptionLineBreakerTests {
    /// Cada carácter mede 1 ponto (o espaço também).
    private func lines(_ runs: [CaptionRun], width: CGFloat) -> [CaptionLine] {
        CaptionLineBreaker.lines(for: runs, maxWidth: width) { CGFloat($0.count) }
    }

    private func texts(_ lines: [CaptionLine]) -> [String] {
        lines.map { $0.words.map(\.text).joined(separator: " ") }
    }

    @Test func wrapsGreedilyAtWordBoundaries() {
        let run = CaptionRun(id: UUID(), text: "aaa bbb ccc ddd", isConfirmed: true)
        #expect(texts(lines([run], width: 7)) == ["aaa bbb", "ccc ddd"])
        #expect(texts(lines([run], width: 11)) == ["aaa bbb ccc", "ddd"])
    }

    @Test func wordsKeepTheirRunState() {
        let final = CaptionRun(id: UUID(), text: "um dois", isConfirmed: true)
        let partial = CaptionRun(id: UUID(), text: "três", isConfirmed: false)
        let result = lines([final, partial], width: 100)
        #expect(result.count == 1)
        #expect(result[0].words.map(\.isConfirmed) == [true, true, false])
    }

    @Test func longWordGetsItsOwnLine() {
        let run = CaptionRun(id: UUID(), text: "a muitolongapalavra b", isConfirmed: true)
        #expect(texts(lines([run], width: 5)) == ["a", "muitolongapalavra", "b"])
    }

    @Test func earlierLinesKeepIdsWhenTextIsAppended() {
        let first = CaptionRun(id: UUID(), text: "aaa bbb ccc", isConfirmed: true)
        let before = lines([first, CaptionRun(id: UUID(), text: "dd", isConfirmed: false)], width: 7)
        let after = lines([first, CaptionRun(id: UUID(), text: "dd eee fff", isConfirmed: false)], width: 7)
        #expect(after.count > before.count)
        #expect(Array(after.prefix(before.count - 1)).map(\.id) == Array(before.prefix(before.count - 1)).map(\.id))
    }

    @Test func emptyInputHasNoLines() {
        #expect(lines([], width: 10).isEmpty)
        #expect(lines([CaptionRun(id: UUID(), text: "   ", isConfirmed: true)], width: 10).isEmpty)
    }
}

// MARK: - Geometria do overlay

struct OverlayLayoutTests {
    @Test func heightDependsOnlyOnSettings() {
        let layout = OverlayLayout.make(mode: .original, translationAvailable: false, fontSize: 28, lineCount: 2, screenWidth: 1512)
        let expected = 2 * OverlayLayout.lineHeight(fontSize: 28) + 2 * OverlayLayout.verticalPadding
        #expect(layout.height == expected)
    }

    @Test func withoutTranslationShowsOnlyOriginal() {
        let layout = OverlayLayout.make(mode: .both, translationAvailable: false, fontSize: 28, lineCount: 2, screenWidth: 1512)
        #expect(layout.blocks.map(\.kind) == [.original])
    }

    @Test func bothModeHasSmallerOriginalAboveTranslation() {
        let layout = OverlayLayout.make(mode: .both, translationAvailable: true, fontSize: 28, lineCount: 2, screenWidth: 1512)
        #expect(layout.blocks.map(\.kind) == [.original, .translation])
        #expect(layout.blocks[0].fontSize < layout.blocks[1].fontSize)
    }

    @Test func widthFitsSmallScreens() {
        let layout = OverlayLayout.make(mode: .original, translationAvailable: false, fontSize: 28, lineCount: 2, screenWidth: 400)
        #expect(layout.width <= 360)
    }

    @Test func positionRoundTrips() {
        let area = CGRect(x: 0, y: 40, width: 1512, height: 900)
        let size = CGSize(width: 1000, height: 100)
        let position = OverlayPosition(x: 0.4, y: 0.2)
        let frame = OverlayLayout.frame(size: size, position: position, in: area)
        let back = OverlayLayout.position(of: frame, in: area)
        #expect(abs(back.x - position.x) < 0.01)
        #expect(abs(back.y - position.y) < 0.01)
    }

    @Test func frameStaysInsideScreen() {
        let area = CGRect(x: 1512, y: 0, width: 1920, height: 1050)
        let size = CGSize(width: 1200, height: 120)
        for position in [OverlayPosition(x: 0, y: 0), OverlayPosition(x: 1, y: 1)] {
            let frame = OverlayLayout.frame(size: size, position: position, in: area)
            #expect(area.contains(frame))
        }
    }
}

struct WordWidthCacheTests {
    @Test func cachesPerFontAndStaysBounded() {
        var cache = WordWidthCache(capacity: 3)
        let small = NSFont.systemFont(ofSize: 12)
        let large = NSFont.systemFont(ofSize: 24)
        let narrow = cache.width(of: "olá", font: small)
        let wide = cache.width(of: "olá", font: large)
        #expect(wide > narrow)
        #expect(cache.width(of: "olá", font: small) == narrow)
        #expect(cache.count == 2)
        _ = cache.width(of: "mundo", font: small)
        _ = cache.width(of: "legendas", font: small)
        #expect(cache.count <= 3)
    }
}
