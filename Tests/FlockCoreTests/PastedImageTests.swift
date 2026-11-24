import XCTest
@testable import FlockCore

final class PastedImageLabelsTests: XCTestCase {
    private let rule = String(repeating: "\u{2500}", count: 40)

    func testALabelIsFoundWhereItIsDrawn() {
        let read = PastedImageLabels(rows: ["", "\u{276F} see [Image #12] here"])
        XCTAssertEqual(read.labels, [
            PastedImageLabel(number: 12, row: 1, column: 6, cells: 11, inPrompt: false, isAttachmentLine: false)
        ])
        XCTAssertNil(read.promptRow)
    }

    func testWideCharactersBeforeALabelTakeTwoCells() {
        XCTAssertEqual(PastedImageLabels(rows: ["\u{6F22}\u{6F22}[Image #1]"]).labels.first?.column, 4)
    }

    func testEveryLabelOnARowIsFound() {
        XCTAssertEqual(PastedImageLabels(rows: ["[Image #1][Image #2] [Image #3]"]).labels.map(\.column), [0, 10, 21])
    }

    func testThePromptIsBetweenTheLastTwoRules() {
        let read = PastedImageLabels(rows: [
            "[Image #1]", rule, "a table", rule, "\u{276F} [Image #2]", rule, "[Image #3] status",
        ])
        XCTAssertEqual(read.promptRow, 3)
        XCTAssertEqual(read.labels.filter(\.inPrompt).map(\.number), [2])
    }

    func testOneRuleIsNoPrompt() {
        let read = PastedImageLabels(rows: [rule, "[Image #1]"])
        XCTAssertNil(read.promptRow)
        XCTAssertEqual(read.labels.map(\.inPrompt), [false])
    }

    func testTheAttachmentLineIsToldFromTheMessage() {
        let read = PastedImageLabels(rows: ["\u{276F} [Image #1] look", "  \u{23BF}  [Image #1]"])
        XCTAssertEqual(read.labels.map(\.isAttachmentLine), [false, true])
    }

    func testOtherBracketsAreNotLabels() {
        XCTAssertEqual(PastedImageLabels(rows: ["[Image #] [Image 3] [image #4] [Image #5"]).labels, [])
    }
}

final class PastedImageMatcherTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 1000)
    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    private func pasted(_ paths: [String], over shown: [Int] = []) -> PastedImageMatcher {
        var matcher = PastedImageMatcher()
        matcher.willPaste(paths, shown: shown, now: start)
        return matcher
    }

    func testAPasteTakesTheLabelThatAppears() {
        var matcher = pasted(["/a.png"], over: [1, 1])
        XCTAssertTrue(matcher.match(shown: [1, 1], now: at(0.1)).isEmpty)
        let matched = matcher.match(shown: [1, 1, 2], now: at(0.2))
        XCTAssertEqual(matched.map(\.number), [2])
        XCTAssertEqual(matched.map(\.path), ["/a.png"])
        XCTAssertFalse(matcher.isWaiting)
    }

    func testSeveralPastesTakeTheirLabelsInOrder() {
        var matcher = pasted(["/a.png", "/b.png", "/c.png"])
        XCTAssertEqual(matcher.match(shown: [5, 4], now: at(0.1)).map(\.path), ["/a.png", "/b.png"])
        let last = matcher.match(shown: [4, 5, 6], now: at(0.2))
        XCTAssertEqual(last.map(\.number), [6])
        XCTAssertEqual(last.map(\.path), ["/c.png"])
    }

    func testANumberAlreadyOnScreenIsTakenOnlyWhenAnotherAppears() {
        var matcher = pasted(["/new.png"], over: [1])
        XCTAssertTrue(matcher.match(shown: [1], now: at(0.1)).isEmpty)
        XCTAssertEqual(matcher.match(shown: [1, 1], now: at(0.2)).map(\.number), [1])
    }

    func testLabelsScrollingAwayMatchNothing() {
        var matcher = pasted(["/a.png"], over: [1, 2])
        XCTAssertTrue(matcher.match(shown: [2], now: at(0.1)).isEmpty)
        XCTAssertTrue(matcher.isWaiting)
    }

    func testAPasteWithNoLabelStopsWaiting() {
        var matcher = pasted(["/a.png"])
        XCTAssertTrue(matcher.match(shown: [], now: at(PastedImageMatcher.window + 1)).isEmpty)
        XCTAssertFalse(matcher.isWaiting)
    }

    func testAPasteAfterAnExpiredOneStartsOver() {
        var matcher = pasted(["/old.png"])
        let later = at(PastedImageMatcher.window + 5)
        matcher.willPaste(["/new.png"], shown: [3], now: later)
        let matched = matcher.match(shown: [3, 4], now: later)
        XCTAssertEqual(matched.map(\.number), [4])
        XCTAssertEqual(matched.map(\.path), ["/new.png"])
    }
}

final class PastedImageIndexTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 10_000_000)
    private var old: Date { now.addingTimeInterval(-PastedImageIndex.maximumAge - 1) }

    func testConversationsKeepTheirOwnNumbers() {
        var index = PastedImageIndex()
        index.set("/a.png", as: 1, in: "one", now: now)
        index.set("/b.png", as: 1, in: "two", now: now)
        XCTAssertEqual(index.images(for: "one"), [1: "/a.png"])
        XCTAssertEqual(index.images(for: "two"), [1: "/b.png"])
        XCTAssertEqual(index.images(for: "three"), [:])
    }

    func testItSurvivesEncoding() throws {
        var index = PastedImageIndex()
        index.set("/a.png", as: 7, in: "one", now: now)
        XCTAssertEqual(try JSONDecoder().decode(PastedImageIndex.self, from: JSONEncoder().encode(index)), index)
    }

    func testPruningForgetsOldConversationsAndNamesWhatNothingUses() {
        var index = PastedImageIndex()
        index.set("/gone.png", as: 1, in: "old", now: old)
        index.set("/shared.png", as: 2, in: "old", now: old)
        index.set("/shared.png", as: 1, in: "new", now: now)
        XCTAssertEqual(index.prune(now: now), ["/gone.png"])
        XCTAssertEqual(index.images(for: "old"), [:])
        XCTAssertEqual(index.images(for: "new"), [1: "/shared.png"])
    }

    func testAnImageJoiningKeepsAConversation() {
        var index = PastedImageIndex()
        index.set("/a.png", as: 1, in: "one", now: old)
        index.set("/b.png", as: 2, in: "one", now: now)
        XCTAssertEqual(index.prune(now: now), [])
        XCTAssertEqual(index.images(for: "one"), [1: "/a.png", 2: "/b.png"])
    }
}

final class PastedImageStripTests: XCTestCase {
    /// Spans 0-100, 110-210, 220-320, 330-430, 440-540 behind 250 points.
    private func strip(at offset: CGFloat) -> PastedImageStrip {
        PastedImageStrip(widths: Array(repeating: 100, count: 5), gap: 10, viewport: 250, offset: offset)
    }

    func testThumbnailsThatFitDoNotPage() {
        let strip = PastedImageStrip(widths: [100, 100], gap: 10, viewport: 210, offset: 0)
        XCTAssertEqual(strip.overflow, 0)
        XCTAssertFalse(strip.canPageBack || strip.canPageForward)
        XCTAssertEqual(strip.shown, 1...2)
        XCTAssertNil(strip.revealing(1))
    }

    func testShownCountsAThumbnailOnceHalfIsInView() {
        XCTAssertEqual(strip(at: 0).shown, 1...2)
        XCTAssertEqual(strip(at: 30).shown, 1...3)
    }

    func testPagingForwardStartsOnTheCutThumbnailAndStopsAtTheEnd() {
        XCTAssertEqual(strip(at: 0).nextPage, 220)
        XCTAssertEqual(strip(at: 220).nextPage, 290)
        XCTAssertFalse(strip(at: 290).canPageForward)
    }

    func testPagingBackEndsOnTheCutThumbnailAndStopsAtTheStart() {
        XCTAssertEqual(strip(at: 290).previousPage, 70)
        XCTAssertEqual(strip(at: 70).previousPage, 0)
        XCTAssertFalse(strip(at: 0).canPageBack)
    }

    func testAThumbnailWiderThanTheViewportStillPages() {
        let wide = PastedImageStrip(widths: [400, 400], gap: 10, viewport: 250, offset: 0)
        XCTAssertEqual(wide.nextPage, 250)
        let end = PastedImageStrip(widths: [400, 400], gap: 10, viewport: 250, offset: 560)
        XCTAssertEqual(end.previousPage, 310)
    }

    func testRevealingScrollsJustFarEnough() {
        XCTAssertNil(strip(at: 0).revealing(1))
        XCTAssertEqual(strip(at: 0).revealing(2), 70)
        XCTAssertEqual(strip(at: 290).revealing(0), 0)
        XCTAssertNil(strip(at: 0).revealing(9))
    }
}

final class QuickLookPlacementTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    private let window = CGRect(x: 200, y: 100, width: 1000, height: 800)

    private func frame(image: CGSize, anchor: CGRect) -> CGRect {
        QuickLookPlacement.frame(
            image: image, anchor: anchor, window: window, visibleScreen: screen, chrome: 30)
    }

    func testItSitsCenteredAboveWhatWasClicked() {
        let anchor = CGRect(x: 600, y: 200, width: 80, height: 20)
        let frame = frame(image: CGSize(width: 500, height: 300), anchor: anchor)
        XCTAssertEqual(frame, CGRect(x: 390, y: 230, width: 500, height: 330))
    }

    func testItGoesUnderWhenThereIsMoreRoomThere() {
        let anchor = CGRect(x: 600, y: 900, width: 80, height: 20)
        let frame = frame(image: CGSize(width: 500, height: 300), anchor: anchor)
        XCTAssertEqual(frame.maxY, 890)
    }

    func testItStaysOnTheScreen() {
        let anchor = CGRect(x: 10, y: 20, width: 20, height: 20)
        let frame = frame(image: CGSize(width: 4000, height: 4000), anchor: anchor)
        XCTAssertTrue(screen.insetBy(dx: 12, dy: 12).contains(frame))
    }

    func testASmallImageKeepsARoomyPanel() {
        let frame = frame(image: CGSize(width: 10, height: 10), anchor: CGRect(x: 600, y: 200, width: 80, height: 20))
        XCTAssertEqual(frame.size, CGSize(width: 360, height: 270))
    }
}

final class PaneDropLabelTests: XCTestCase {
    func testItNamesAndCountsWhatWouldLand() {
        XCTAssertEqual(PaneDropLabel.text(count: 1, allImages: true), "Drop image")
        XCTAssertEqual(PaneDropLabel.text(count: 3, allImages: true), "Drop 3 images")
        XCTAssertEqual(PaneDropLabel.text(count: 2, allImages: false), "Drop 2 files")
    }
}
