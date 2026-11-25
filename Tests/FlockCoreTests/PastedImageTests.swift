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

    func testALabelWrappedOntoTheNextRowIsOneLabel() {
        let read = PastedImageLabels(rows: [rule, "\u{276F} [Image #1] see [Image   ", "  #2] and [Image #3]", rule])
        XCTAssertEqual(read.labels, [
            PastedImageLabel(number: 1, row: 1, column: 2, cells: 10, inPrompt: true, isAttachmentLine: false),
            PastedImageLabel(
                number: 2, row: 1, column: 17, cells: 6, inPrompt: true, isAttachmentLine: false,
                tail: .init(column: 2, cells: 3)),
            PastedImageLabel(number: 3, row: 2, column: 10, cells: 10, inPrompt: true, isAttachmentLine: false),
        ])
    }

    func testARowThatOnlyLooksCutOffIsNotALabel() {
        XCTAssertEqual(PastedImageLabels(rows: ["an [Image", "of something #2]"]).labels, [])
        XCTAssertEqual(PastedImageLabels(rows: ["[Image #1]", "#2]"]).labels.map(\.number), [1])
        XCTAssertEqual(PastedImageLabels(rows: ["[Image"]).labels, [])
    }

    func testAPastedTextIsItsOwnKindOfLabel() {
        let read = PastedImageLabels(rows: ["[Image #1] [Pasted text #2] [Pasted text #3] [Pasted text #4 +12 lines]"])
        XCTAssertEqual(read.labels.map(\.number), [1])
        XCTAssertEqual(read.texts.map(\.number), [2, 3])
        XCTAssertEqual(read.texts.map(\.column), [11, 28])
        XCTAssertEqual(read.texts.map(\.cells), [16, 16])
    }

    func testAPastedTextWrappedAtAnySpaceIsOneLabel() {
        for (first, second) in [("[Pasted", "text #14]"), ("[Pasted text", "#14]")] {
            let read = PastedImageLabels(rows: [rule, "\u{276F} a \(first)", "  \(second) b", rule])
            XCTAssertEqual(read.texts, [PastedImageLabel(
                kind: .text, number: 14, row: 1, column: 4, cells: first.count, inPrompt: true,
                isAttachmentLine: false, tail: .init(column: 2, cells: second.count))], first)
            XCTAssertEqual(read.labels, [])
        }
    }

    func testOtherBracketsAreNotLabels() {
        XCTAssertEqual(PastedImageLabels(rows: ["[Image #] [Image 3] [image #4] [Image #5"]).labels, [])
    }
}

final class PastedImageMatcherTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 1000)
    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    private let rule = String(repeating: "\u{2500}", count: 40)

    /// `sent` is drawn above a prompt holding `prompt`.
    private func screen(prompt: [Int], sent: [Int] = []) -> PastedImageLabels {
        func row(_ numbers: [Int]) -> String { numbers.map { "[Image #\($0)]" }.joined(separator: " ") }
        return PastedImageLabels(rows: [row(sent), rule, row(prompt), rule])
    }

    private func bare(_ numbers: [Int]) -> PastedImageLabels {
        PastedImageLabels(rows: numbers.map { "[Image #\($0)]" })
    }

    private func pasted(_ paths: [String], over screen: PastedImageLabels) -> PastedImageMatcher {
        var matcher = PastedImageMatcher()
        _ = matcher.willPaste(paths, over: screen, now: start)
        return matcher
    }

    func testAPasteTakesTheLabelThatAppears() {
        var matcher = pasted(["/a.png"], over: screen(prompt: [1]))
        XCTAssertTrue(matcher.match(screen(prompt: [1]), now: at(0.1)).isEmpty)
        let matched = matcher.match(screen(prompt: [1, 2]), now: at(0.2))
        XCTAssertEqual(matched.map(\.number), [2])
        XCTAssertEqual(matched.map(\.path), ["/a.png"])
        XCTAssertFalse(matcher.isWaiting)
    }

    func testSeveralPastesTakeTheirLabelsInOrder() {
        var matcher = pasted(["/a.png", "/b.png", "/c.png"], over: screen(prompt: []))
        XCTAssertEqual(matcher.match(screen(prompt: [5, 4]), now: at(0.1)).map(\.path), ["/a.png", "/b.png"])
        let last = matcher.match(screen(prompt: [4, 5, 6]), now: at(0.2))
        XCTAssertEqual(last.map(\.number), [6])
        XCTAssertEqual(last.map(\.path), ["/c.png"])
    }

    func testASentMessageScrollingInTakesNothing() {
        var matcher = pasted(["/a.png"], over: screen(prompt: []))
        XCTAssertTrue(matcher.match(screen(prompt: [], sent: [1, 2]), now: at(0.1)).isEmpty)
        XCTAssertEqual(matcher.match(screen(prompt: [3], sent: [1, 2]), now: at(0.2)).map(\.number), [3])
    }

    func testAScreenWithoutThePromptTakesNothing() {
        var matcher = pasted(["/a.png"], over: screen(prompt: []))
        XCTAssertTrue(matcher.match(bare([1, 2]), now: at(0.1)).isEmpty)
        XCTAssertTrue(matcher.isWaiting)
    }

    func testAProgramWithNoPromptIsMatchedOnItsWholeScreen() {
        var matcher = pasted(["/a.png"], over: bare([1]))
        XCTAssertEqual(matcher.match(bare([1, 2]), now: at(0.1)).map(\.number), [2])
    }

    func testALabelThatScrollsOffAndBackTakesNothing() {
        var matcher = pasted(["/a.png"], over: bare([1, 2]))
        XCTAssertTrue(matcher.match(bare([2]), now: at(0.1)).isEmpty)
        XCTAssertTrue(matcher.match(bare([1, 2]), now: at(0.2)).isEmpty)
        XCTAssertEqual(matcher.match(bare([1, 2, 3]), now: at(0.3)).map(\.number), [3])
    }

    func testACancelledPasteLeavesTheNextItsOwnLabel() {
        var matcher = PastedImageMatcher()
        let failed = matcher.willPaste(["/failed.png"], over: screen(prompt: []), now: start)
        _ = matcher.willPaste(["/kept.png"], over: screen(prompt: []), now: at(0.1))
        matcher.cancel(failed)
        XCTAssertEqual(matcher.match(screen(prompt: [1]), now: at(0.2)).map(\.path), ["/kept.png"])
    }

    func testAHeldPasteWaitsUntilItIsSentAndThenForItsOwnWindow() {
        var matcher = PastedImageMatcher()
        let paste = matcher.willPaste(["/a.png"], over: screen(prompt: []), held: true, now: start)
        XCTAssertTrue(matcher.match(screen(prompt: []), now: at(300)).isEmpty)
        XCTAssertTrue(matcher.isWaiting)
        matcher.sent(paste, now: at(300))
        XCTAssertEqual(matcher.match(screen(prompt: [1]), now: at(301)).map(\.path), ["/a.png"])
    }

    func testUploadsThatFinishOutOfOrderKeepTheirOwnLabels() {
        var matcher = PastedImageMatcher()
        let slow = matcher.willPaste(["/slow.png"], over: screen(prompt: []), held: true, now: start)
        let quick = matcher.willPaste(["/quick.png"], over: screen(prompt: []), held: true, now: start)
        matcher.sent(quick, now: at(1))
        XCTAssertEqual(matcher.match(screen(prompt: [1]), now: at(2)).map(\.path), ["/quick.png"])
        matcher.sent(slow, now: at(3))
        XCTAssertEqual(matcher.match(screen(prompt: [1, 2]), now: at(4)).map(\.path), ["/slow.png"])
    }

    func testAFileTakesAPastedTextsLabelAndAnImageDoesNot() {
        var images = PastedImageMatcher(.image)
        var files = PastedImageMatcher(.text)
        _ = images.willPaste(["/a.png"], over: screen(prompt: []), now: start)
        _ = files.willPaste(["/a.js"], over: screen(prompt: []), now: start)
        let both = PastedImageLabels(rows: [rule, "[Pasted text #4] [Image #5]", rule])
        XCTAssertEqual(images.match(both, now: at(1)).map(\.number), [5])
        XCTAssertEqual(files.match(both, now: at(1)).map(\.number), [4])
    }

    func testAPasteFromBeforeAResetCancelsNothingAfterIt() {
        var matcher = PastedImageMatcher()
        let old = matcher.willPaste(["/old.png"], over: screen(prompt: []), held: true, now: start)
        matcher.reset()
        _ = matcher.willPaste(["/new.png"], over: screen(prompt: []), now: at(1))
        matcher.cancel(old)
        XCTAssertEqual(matcher.match(screen(prompt: [1]), now: at(2)).map(\.path), ["/new.png"])
    }

    func testAnUnlabelledPasteDoesNotOutliveItsOwnWindow() {
        var matcher = pasted(["/never.png"], over: screen(prompt: []))
        _ = matcher.willPaste(["/kept.png"], over: screen(prompt: []), now: at(10))
        XCTAssertEqual(
            matcher.match(screen(prompt: [1]), now: at(PastedImageMatcher.window + 1)).map(\.path), ["/kept.png"])
    }

    func testALabelAfterTheWindowTakesNothing() {
        var matcher = pasted(["/a.png"], over: screen(prompt: []))
        XCTAssertTrue(matcher.match(screen(prompt: [1]), now: at(PastedImageMatcher.window + 1)).isEmpty)
        XCTAssertFalse(matcher.isWaiting)
    }

    func testAPasteAfterAnExpiredOneStartsOver() {
        var matcher = pasted(["/old.png"], over: screen(prompt: []))
        let later = at(PastedImageMatcher.window + 5)
        _ = matcher.willPaste(["/new.png"], over: screen(prompt: [3]), now: later)
        let matched = matcher.match(screen(prompt: [3, 4]), now: later)
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
        index.prune(now: now)
        XCTAssertEqual(index.livePaths, ["/shared.png"])
        XCTAssertEqual(index.images(for: "old"), [:])
        XCTAssertEqual(index.images(for: "new"), [1: "/shared.png"])
    }

    func testAnImageJoiningKeepsAConversation() {
        var index = PastedImageIndex()
        index.set("/a.png", as: 1, in: "one", now: old)
        index.set("/b.png", as: 2, in: "one", now: now)
        index.prune(now: now)
        XCTAssertFalse(index.images(for: "one").isEmpty)
        XCTAssertEqual(index.images(for: "one"), [1: "/a.png", 2: "/b.png"])
    }

    func testFilesAndImagesKeepTheirOwnNumbers() throws {
        var index = PastedImageIndex()
        index.set("/a.png", as: 1, in: "one", now: now)
        index.set("/a.js", asFile: 1, in: "one", now: now)
        XCTAssertEqual(index.images(for: "one"), [1: "/a.png"])
        XCTAssertEqual(index.files(for: "one"), [1: "/a.js"])
        XCTAssertEqual(try JSONDecoder().decode(PastedImageIndex.self, from: JSONEncoder().encode(index)), index)
    }

    func testAnIndexFromBeforeThereWereFilesStillReads() throws {
        let old = Data(#"{"one":{"updated":10000000,"images":{"1":"/a.png"}}}"#.utf8)
        let index = try JSONDecoder().decode(PastedImageIndex.self, from: old)
        XCTAssertEqual(index.images(for: "one"), [1: "/a.png"])
        XCTAssertEqual(index.files(for: "one"), [:])
    }

    func testAConversationInUseIsKept() {
        var index = PastedImageIndex()
        index.set("/a.png", as: 1, in: "one", now: old)
        XCTAssertTrue(index.touch("one", now: now))
        XCTAssertFalse(index.touch("two", now: now))
        index.prune(now: now)
        XCTAssertFalse(index.images(for: "one").isEmpty)
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

final class FileMentionTests: XCTestCase {
    private func mention(_ path: String) throws -> String {
        let paste = try XCTUnwrap(FileMention.paste(for: path, drop: 0))
        return String(paste[try XCTUnwrap(paste.firstIndex(of: "@"))...])
    }

    func testAFileIsNamedInFullAndQuoted() throws {
        XCTAssertEqual(try mention("/Users/acme/app/src/a.swift"), "@\"/Users/acme/app/src/a.swift\"")
        XCTAssertEqual(try mention("/tmp/my @icons/a.js"), "@\"/tmp/my @icons/a.js\"")
    }

    func testAPathTheQuotesCannotHoldIsLeftAlone() {
        XCTAssertNil(FileMention.paste(for: "/tmp/a\"b.js", drop: 0))
        XCTAssertNil(FileMention.paste(for: "/tmp/a\nb.js", drop: 0))
    }

    /// What Claude Code folds, and into the label with no line count.
    func testEveryPasteFoldsIntoTheShortestLabel() throws {
        for path in ["/a", "/tmp/" + String(repeating: "long/", count: 300) + "a.js"] {
            let paste = try XCTUnwrap(FileMention.paste(for: path, drop: 0))
            XCTAssertGreaterThan(paste.count, 800)
            XCTAssertFalse(paste.contains(where: \.isNewline))
            XCTAssertEqual(paste, paste.trimmingCharacters(in: .whitespaces))
        }
    }

    func testTheSameFileTwiceIsNotTheSamePaste() {
        XCTAssertNotEqual(FileMention.paste(for: "/a.js", drop: 1), FileMention.paste(for: "/a.js", drop: 2))
    }

    func testOnlyAnAgentThatReadsMentionsIsHandedOne() {
        XCTAssertTrue(FileMention.isRead(by: "claude"))
        XCTAssertFalse(FileMention.isRead(by: "codex"))
        XCTAssertFalse(FileMention.isRead(by: nil))
    }
}

final class PreviewPanelRuleTests: XCTestCase {
    func testThePressThatClosedThePanelIsHeldBackUntilItIsLetGo() {
        XCTAssertTrue(HeldKey.read(53, isDown: true, isRepeat: true, of: 53) == (true, false))
        XCTAssertTrue(HeldKey.read(53, isDown: false, isRepeat: false, of: 53) == (true, true))
        XCTAssertTrue(HeldKey.read(53, isDown: true, isRepeat: false, of: 53) == (false, true), "a new press")
        XCTAssertTrue(HeldKey.read(53, isDown: true, isRepeat: true, of: 49) == (false, false))
    }

    func testASmallImageGrowsOnlyAsItsPanelDoes() {
        let placed = CGSize(width: 360, height: 240)
        XCTAssertEqual(
            QuickLookPlacement.image(CGSize(width: 40, height: 40), in: placed, placedIn: placed),
            CGRect(x: 160, y: 100, width: 40, height: 40))
        XCTAssertEqual(
            QuickLookPlacement.image(CGSize(width: 40, height: 40), in: CGSize(width: 720, height: 600), placedIn: placed).width, 80)
        XCTAssertEqual(
            QuickLookPlacement.image(CGSize(width: 720, height: 480), in: CGSize(width: 180, height: 240), placedIn: placed).width, 180)
    }
}
