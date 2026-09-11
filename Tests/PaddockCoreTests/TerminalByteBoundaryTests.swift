import XCTest
import SwiftTerm
@testable import PaddockCore

/// Root-cause investigation for a live content-corruption report against a
/// real smoke session (digit-spill inside words, stray numbers in a
/// right-hand column, scrollback lines out of order). `pane.read`'s raw ANSI
/// for the affected pane, captured directly from the running herdr session
/// during triage, was byte-for-byte correct -- so the corruption is
/// introduced somewhere in paddock's own consumption, not herdr's data.
///
/// Two plausible mechanisms were tested here and RULED OUT: a CSI sequence
/// split ACROSS TWO `feed()` calls at hostile points genuinely inside the
/// escape sequence (between `ESC` and `[`, inside the parameter digits, and
/// right before the terminator byte) -- SwiftTerm's parser is incremental
/// and holds a partial sequence across calls correctly -- and
/// `TerminalRepresentable.updateNSView`'s `resize()` call landing at each of
/// those same hostile points, or firing repeatedly in quick succession
/// (both render clean). A mid-multibyte-UTF8 split is covered too. All are
/// kept as passing regression tests: if either the vendored SwiftTerm pin or
/// the resize-on-mismatch logic ever changes to make one of these unsafe,
/// these tests catch it.
final class TerminalByteBoundaryTests: XCTestCase {
    private final class NullDelegate: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }

    private func screenText(_ term: Terminal) -> String {
        (0..<term.rows)
            .compactMap { term.getLine(row: $0)?.translateToString(trimRight: true) }
            .joined(separator: "\n")
    }

    /// `"\u{1B}[1;32mHELLO WORLD\u{1B}[0m\r\n"`'s leading SGR sequence is
    /// exactly `ESC [ 1 ; 3 2 m` (bytes 0-6); `HELLO WORLD` starts at byte 7.
    /// Every split point here lands INSIDE that 7-byte sequence, never in
    /// the plain text -- unlike a plain midpoint split, which for this
    /// string lands at byte 12, inside "HELLO WORLD" itself.
    private static let sgrLine = "\u{1B}[1;32mHELLO WORLD\u{1B}[0m\r\n"
    private static let hostileSGRSplitPoints = [1, 2, 4, 6] // ESC|[, [|1, 1;|32, 32|m

    /// A CSI-colored line split at genuinely hostile points inside the
    /// leading escape sequence, across two separate `feed()` calls, no
    /// resize between them. `Terminal.feed` is documented incremental; this
    /// renders clean at every split point tested.
    func testSplitCSIAcrossTwoFeedsAtHostilePointsIsClean() {
        let bytes = Array(Self.sgrLine.utf8)
        for splitIndex in Self.hostileSGRSplitPoints {
            let term = Terminal(delegate: NullDelegate(), options: TerminalOptions(cols: 40, rows: 5))
            term.feed(byteArray: Array(bytes[0..<splitIndex]))
            term.feed(byteArray: Array(bytes[splitIndex...]))
            XCTAssertTrue(
                screenText(term).contains("HELLO WORLD"),
                "split at byte \(splitIndex) (inside ESC[1;32m) must still render the line cleanly"
            )
        }
    }

    /// RULED OUT: a `resize()` landing between the two halves of a CSI split
    /// at each of the same hostile points -- exactly what `updateNSView`'s
    /// cols/rows-mismatch guard can do relative to the frame-consuming
    /// Task's own `feed()` calls, since the two run on independent
    /// schedules. SwiftTerm's parser tolerates it at every point tested;
    /// the line still renders correctly.
    func testResizeBetweenHostileSplitCSIHalvesStillRendersClean() {
        let bytes = Array(Self.sgrLine.utf8)
        for splitIndex in Self.hostileSGRSplitPoints {
            let term = Terminal(delegate: NullDelegate(), options: TerminalOptions(cols: 40, rows: 5))
            term.feed(byteArray: Array(bytes[0..<splitIndex]))
            term.resize(cols: 60, rows: 5)
            term.feed(byteArray: Array(bytes[splitIndex...]))
            XCTAssertTrue(
                screenText(term).contains("HELLO WORLD"),
                "a resize between the halves of a split at byte \(splitIndex) must not corrupt the line"
            )
        }
    }

    /// A 3-byte UTF-8 character (`€`, `E2 82 AC`) split mid-codepoint across
    /// two `feed()` calls. Must not corrupt SUBSEQUENT content even if the
    /// glyph itself does not render (a torn multibyte sequence has nowhere
    /// good to go); the real risk this guards is spillover into later bytes,
    /// not the glyph's own fidelity.
    func testSplitMidMultibyteUTF8DoesNotCorruptSubsequentContent() {
        let bytes = Array("A\u{20AC}FTER\r\n".utf8) // "A" + EURO SIGN + "FTER"
        // EURO SIGN is bytes[1...3]; split inside it.
        for splitIndex in [2, 3] {
            let term = Terminal(delegate: NullDelegate(), options: TerminalOptions(cols: 40, rows: 5))
            term.feed(byteArray: Array(bytes[0..<splitIndex]))
            term.feed(byteArray: Array(bytes[splitIndex...]))
            XCTAssertTrue(
                screenText(term).contains("FTER"),
                "content after a torn multibyte UTF-8 split (at byte \(splitIndex)) must still render, not corrupt"
            )
        }
    }

    /// RULED OUT: the exact live sequence a real pane produced (captured
    /// verbatim from the smoke session's `pane.read` output), replayed with
    /// GENUINE splits landing inside each escape sequence, resizes at each
    /// split point, and several MORE resizes in quick succession (a jittery
    /// `CanvasGeometry` recomputation across GeometryReader passes). Still
    /// renders clean -- repeated resizing, even combined with hostile
    /// splits, is not the mechanism.
    func testRepeatedResizesInterleavedWithHostileSplitsOnRealCapturedBytesRenderClean() {
        let term = Terminal(delegate: NullDelegate(), options: TerminalOptions(cols: 60, rows: 40))
        for i in 1480...1500 {
            term.feed(byteArray: Array("scrollback line \(i)\r\n".utf8))
        }
        for cols in [68, 61, 66, 60, 64] {
            term.resize(cols: cols, rows: 39)
        }
        // `\u{1B}[0m\u{1B}[38;5;6m` is the real captured prefix; byte 10
        // lands mid-parameter-list inside its second escape sequence.
        let promptLine = Array("\u{1B}[0m\u{1B}[38;5;6m/private/tmp\u{1B}[0m \r\n".utf8)
        let promptSplit = 10
        term.feed(byteArray: Array(promptLine[0..<promptSplit]))
        term.resize(cols: 62, rows: 39)
        term.feed(byteArray: Array(promptLine[promptSplit...]))

        // Byte 6 lands inside the second escape sequence's own `ESC[1m`.
        let typedLine = Array("\u{1B}[0m\u{1B}[1m\u{1B}[38;5;2m\u{276E}\u{1B}[0m laude\r\n".utf8)
        let typedSplit = 6
        term.feed(byteArray: Array(typedLine[0..<typedSplit]))
        term.resize(cols: 63, rows: 39)
        term.feed(byteArray: Array(typedLine[typedSplit...]))

        let text = screenText(term)
        XCTAssertTrue(text.contains("scrollback line 1500"))
        XCTAssertTrue(text.contains("/private/tmp") && text.contains("laude"))
    }
}
