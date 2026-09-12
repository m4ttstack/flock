import XCTest
import SwiftTerm
@testable import PaddockCore

/// Records `showCursor`/`hideCursor` calls in order, so a test can assert
/// the backfill-then-full-frame cursor contract directly instead of
/// inferring it from screen text (which cannot express "hidden").
private final class CursorEventRecordingDelegate: TerminalDelegate {
    private(set) var events: [String] = []
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
    func showCursor(source: Terminal) { events.append("show") }
    func hideCursor(source: Terminal) { events.append("hide") }
}

final class PaneTerminalTests: XCTestCase {
    private static var fixturePath: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/observe.ndjson")
            .path
    }

    private func fixtureFrames() throws -> [TerminalFrame] {
        try Data(contentsOf: URL(fileURLWithPath: Self.fixturePath))
            .split(separator: 0x0A)
            .compactMap { line -> TerminalFrame? in
                guard case .frame(let frame) = ObserveWireLine.parse(Data(line)) else { return nil }
                return frame
            }
    }

    // MARK: - Step 1: brief's three tests

    func testScreenTextContainsKnownFixtureTextAfterFeedingObserveNdjson() throws {
        let term = PaneTerminal(cols: 80, rows: 24)
        for frame in try fixtureFrames() {
            term.ingest(frame)
        }

        let text = term.screenText()
        XCTAssertTrue(text.contains("/private/tmp"), "expected the fixture's shell prompt cwd")
        XCTAssertTrue(text.contains("line 12 red done"), "expected the fixture's final printf output")
    }

    func testFullFrameResetsPriorStateBeforePainting() {
        let term = PaneTerminal(cols: 10, rows: 3)
        term.ingest(TerminalFrame(seq: 1, full: false, width: 10, height: 3, bytes: Data("\u{1B}[1;1HAAAAAAAAAA".utf8)))
        XCTAssertTrue(term.screenText().contains("AAAAAAAAAA"))

        // A full frame paints fresh content elsewhere without clearing row 1
        // itself: resetToInitialState() must run before feeding, or the
        // stale "A" row survives underneath the new paint.
        term.ingest(TerminalFrame(seq: 2, full: true, width: 10, height: 3, bytes: Data("\u{1B}[2;1HBBBB".utf8)))

        let text = term.screenText()
        XCTAssertFalse(text.contains("AAAAAAAAAA"), "full frame must reset prior state before painting")
        XCTAssertTrue(text.contains("BBBB"))
    }

    func testBackfillThenFramesProduceBackfillTextAboveLiveText() {
        let term = PaneTerminal(cols: 20, rows: 4)
        // pane.read --source recent returns scrollback oldest-first; a CRLF
        // leaves the cursor on the next row for the live frame to continue
        // from, exactly the seam spike 4 found torn only when cols/rows
        // mismatched the pane's real size.
        term.seedBackfill(ansi: Data("BACKFILL-LINE\r\n".utf8))
        term.ingest(TerminalFrame(seq: 1, full: false, width: 20, height: 4, bytes: Data("LIVE-LINE".utf8)))

        let lines = term.screenText().split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let backfillRow = lines.firstIndex(where: { $0.contains("BACKFILL-LINE") }) else {
            return XCTFail("backfill text missing from screenText()")
        }
        guard let liveRow = lines.firstIndex(where: { $0.contains("LIVE-LINE") }) else {
            return XCTFail("live text missing from screenText()")
        }
        XCTAssertLessThan(backfillRow, liveRow, "backfill text must render above live text")
    }

    // MARK: - backfill cursor hide (stray hollow-cursor regression)

    /// Backfill text carries no cursor-position escape at all (confirmed
    /// against a live pane's `pane.read --source recent --format ansi`
    /// dump, which ends the instant its visible glyphs do). Feeding it
    /// unprefixed leaves the cursor visible wherever the naive glyph stream
    /// happens to end -- almost never the pane's real cursor cell. Seeding
    /// must hide it instead, with no `show` yet: nothing describes where
    /// the real cursor belongs until a live frame says so.
    func testSeedBackfillHidesCursorWithNoCorrespondingShow() {
        let delegate = CursorEventRecordingDelegate()
        let term = PaneTerminal(cols: 20, rows: 4, delegate: delegate)
        term.seedBackfill(ansi: Data("BACKFILL-LINE\r\n".utf8))
        XCTAssertEqual(delegate.events, ["hide"])
    }

    /// A live full frame always brackets its redraw with a leading
    /// `?25l` and a trailing absolute-position-then-`?25h` (confirmed
    /// against a real captured frame: `...\u{1B}[3;5H\u{1B}[?25h`). That
    /// trailing show is what actually reveals the cursor, at the frame's
    /// own authoritative position -- correcting whatever backfill left
    /// behind rather than compounding it. Only one more `hide` event, not
    /// two: `resetToInitialState()` (the full-frame reset) saves and
    /// restores `cursorHidden` around its own state rebuild, so a
    /// full-frame's own leading `?25l` finds the cursor already hidden
    /// from `seedBackfill` and fires no second delegate call.
    func testFullFrameShowsCursorAtItsOwnPositionAfterBackfillHidIt() {
        let delegate = CursorEventRecordingDelegate()
        let term = PaneTerminal(cols: 20, rows: 4, delegate: delegate)
        term.seedBackfill(ansi: Data("BACKFILL-LINE\r\n".utf8))
        term.ingest(TerminalFrame(
            seq: 1, full: true, width: 20, height: 4,
            bytes: Data("\u{1B}[?25l\u{1B}[2;1HLIVE-LINE\u{1B}[2;5H\u{1B}[?25h".utf8)
        ))
        XCTAssertEqual(delegate.events, ["hide", "show"])
    }

    // MARK: - known SwiftTerm 1.20.0 issue (spike 4, FINDINGS.md Caveat 2)

    /// Pins a known SwiftTerm 1.20.0 gap: an astral-plane (4-byte UTF-8)
    /// emoji is silently dropped by `feed(byteArray:)` (cell reads back
    /// blank, not even a placeholder glyph). This documents CURRENT
    /// behavior, not a requirement -- if a future SwiftTerm pin bump fixes
    /// it, this test fails loudly instead of the regression going unnoticed.
    /// Re-check upstream before bumping the pin past 1.20.0.
    func testKnownIssueAstralPlaneEmojiIsDroppedBySwiftTerm120() {
        let term = PaneTerminal(cols: 20, rows: 2)
        let rocketEmojiUTF8: [UInt8] = [0xF0, 0x9F, 0x9A, 0x80] // U+1F680 ROCKET
        term.ingest(TerminalFrame(seq: 1, full: false, width: 20, height: 2, bytes: Data(rocketEmojiUTF8)))

        XCTAssertFalse(
            term.screenText().contains("\u{1F680}"),
            "known SwiftTerm 1.20.0 issue: astral-plane emoji dropped by feed(byteArray:); "
                + "if this now fails, SwiftTerm has fixed it -- update this test and FINDINGS.md"
        )
    }
}
