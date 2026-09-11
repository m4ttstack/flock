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
/// split across two `feed()` calls (SwiftTerm's parser is incremental and
/// handles this correctly), and `TerminalRepresentable.updateNSView`'s
/// `resize()` call landing between two halves of a split sequence, or
/// firing repeatedly in quick succession (both render clean). Both are kept
/// as passing regression tests: if either the vendored SwiftTerm pin or the
/// resize-on-mismatch logic ever changes to make one of these unsafe, these
/// tests catch it.
final class TerminalByteBoundaryTests: XCTestCase {
    private final class NullDelegate: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }

    private func screenText(_ term: Terminal) -> String {
        (0..<term.rows)
            .compactMap { term.getLine(row: $0)?.translateToString(trimRight: true) }
            .joined(separator: "\n")
    }

    /// A CSI-colored line split mid-escape-sequence across two separate
    /// `feed()` calls, no resize between them. `Terminal.feed` is
    /// documented incremental; this renders clean.
    func testSplitCSIAcrossTwoFeedsWithNoResizeIsClean() {
        let term = Terminal(delegate: NullDelegate(), options: TerminalOptions(cols: 40, rows: 5))
        let bytes = Array("\u{1B}[1;32mHELLO WORLD\u{1B}[0m\r\n".utf8)
        let mid = bytes.count / 2
        term.feed(byteArray: Array(bytes[0..<mid]))
        term.feed(byteArray: Array(bytes[mid...]))
        XCTAssertTrue(screenText(term).contains("HELLO WORLD"))
    }

    /// RULED OUT: a `resize()` landing between two halves of one CSI
    /// sequence -- exactly what `updateNSView`'s cols/rows-mismatch guard
    /// can do relative to the frame-consuming Task's own `feed()` calls,
    /// since the two run on independent schedules. SwiftTerm's parser
    /// tolerates it; the line still renders correctly.
    func testResizeBetweenSplitCSIHalvesStillRendersClean() {
        let term = Terminal(delegate: NullDelegate(), options: TerminalOptions(cols: 40, rows: 5))
        let bytes = Array("\u{1B}[1;32mHELLO WORLD\u{1B}[0m\r\n".utf8)
        let mid = bytes.count / 2
        term.feed(byteArray: Array(bytes[0..<mid]))
        term.resize(cols: 60, rows: 5)
        term.feed(byteArray: Array(bytes[mid...]))
        XCTAssertTrue(screenText(term).contains("HELLO WORLD"))
    }

    /// RULED OUT: the exact live sequence a real pane produced (captured
    /// verbatim from the smoke session's `pane.read` output), replayed with
    /// a resize landing where `updateNSView` could plausibly have fired
    /// one, and with several MORE resizes in quick succession (a jittery
    /// `CanvasGeometry` recomputation across GeometryReader passes). Still
    /// renders clean -- repeated resizing alone is not the mechanism.
    func testRepeatedResizesInterleavedWithFeedsOnRealCapturedBytesRenderClean() {
        let term = Terminal(delegate: NullDelegate(), options: TerminalOptions(cols: 60, rows: 40))
        for i in 1480...1500 {
            term.feed(byteArray: Array("scrollback line \(i)\r\n".utf8))
        }
        for cols in [68, 61, 66, 60, 64] {
            term.resize(cols: cols, rows: 39)
        }
        term.feed(byteArray: Array("\u{1B}[0m\u{1B}[38;5;6m/private/tmp\u{1B}[0m \r\n".utf8))
        term.resize(cols: 62, rows: 39)
        term.feed(byteArray: Array("\u{1B}[0m\u{1B}[1m\u{1B}[38;5;2m\u{276E}\u{1B}[0m laude\r\n".utf8))

        let text = screenText(term)
        XCTAssertTrue(text.contains("scrollback line 1500"))
        XCTAssertTrue(text.contains("/private/tmp") && text.contains("laude"))
    }
}
