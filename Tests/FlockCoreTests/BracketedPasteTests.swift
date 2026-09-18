import XCTest
@testable import FlockCore

/// The rule in one line: a paste leaves flock as exactly one bracketed paste,
/// and nothing in the pasted text can make it anything else.
final class BracketedPasteTests: XCTestCase {
    private let start = Data("\u{1B}[200~".utf8)
    private let end = Data("\u{1B}[201~".utf8)

    func testAPasteIsFramedByTheBracketedPasteMarkers() {
        XCTAssertEqual(
            BracketedPaste.payload("hello"),
            Data("\u{1B}[200~hello\u{1B}[201~".utf8)
        )
    }

    /// The bug this rule exists for: an escaped screenshot path is only an
    /// attachment to the program in the pane when it arrives framed.
    func testAnEscapedScreenshotPathIsFramed() {
        let path = "/Users/matt/Screenshots/CleanShot\\ 2026-09-18\\ at\\ 9.01.07\\ AM.png"
        XCTAssertEqual(
            BracketedPaste.payload(path),
            Data("\u{1B}[200~\(path)\u{1B}[201~".utf8)
        )
    }

    /// A newline inside the frame is data, which is the whole point of framing
    /// one: unframed it is an Enter, and a multi-line paste runs line by line.
    func testANewlineSurvivesTheFrame() {
        XCTAssertEqual(
            BracketedPaste.payload("first\nsecond"),
            Data("\u{1B}[200~first\nsecond\u{1B}[201~".utf8)
        )
    }

    func testMultiByteTextSurvivesTheFrame() {
        XCTAssertEqual(
            BracketedPaste.payload("naïve → 🙂"),
            Data("\u{1B}[200~naïve → 🙂\u{1B}[201~".utf8)
        )
    }

    /// Ghostty replaces each of these with a space on every text insertion,
    /// bracketed or not (`Vendor/ghostty/src/input/paste.zig`), and this text
    /// used to reach the pane through that path.
    func testEveryByteXtermStripsBecomesASpace() {
        let stripped: [UInt8] = [
            0x00, 0x08, 0x05, 0x04, 0x1B, 0x7F,
            0x03, 0x1C, 0x15, 0x1A, 0x11, 0x13, 0x17, 0x16, 0x12, 0x0F,
        ]
        for byte in stripped {
            let text = String(decoding: [UInt8(ascii: "a"), byte, UInt8(ascii: "b")], as: UTF8.self)
            XCTAssertEqual(
                BracketedPaste.payload(text),
                Data("\u{1B}[200~a b\u{1B}[201~".utf8),
                "byte 0x\(String(byte, radix: 16)) was not replaced with a space"
            )
        }
    }

    func testTabsAndCarriageReturnsAreNotStripped() {
        XCTAssertEqual(
            BracketedPaste.payload("a\tb\rc"),
            Data("\u{1B}[200~a\tb\rc\u{1B}[201~".utf8)
        )
    }

    /// herdr takes a client's bytes as a paste only when they are EXACTLY one
    /// complete bracketed paste: the start marker leading, the end marker
    /// closing it and appearing nowhere earlier
    /// (`src/raw_input.rs`'s `complete_text_bracketed_paste`). Bytes that miss
    /// that shape are forwarded as typed input, markers and all, so no pasted
    /// text may be able to break it.
    func testTheFrameHoldsHoweverStrangeTheText() throws {
        let texts = [
            "plain",
            "before\u{1B}[201~after",
            "\u{1B}[200~already framed\u{1B}[201~",
            "\u{1B}[201~",
            "\u{0}\u{3}\u{7F}",
        ]
        for text in texts {
            let payload = try XCTUnwrap(BracketedPaste.payload(text), "no payload for \(text.debugDescription)")
            XCTAssertTrue(payload.starts(with: start), "no start marker for \(text.debugDescription)")
            XCTAssertEqual(payload.suffix(end.count), end, "no end marker for \(text.debugDescription)")
            XCTAssertEqual(
                occurrences(of: end, in: payload), 1,
                "the end marker is not unique for \(text.debugDescription)"
            )
            XCTAssertEqual(
                occurrences(of: start, in: payload), 1,
                "the start marker is not unique for \(text.debugDescription)"
            )
        }
    }

    func testEmptyTextHasNoPayload() {
        XCTAssertNil(BracketedPaste.payload(""))
    }

    /// Text that is nothing but stripped bytes still pastes: it becomes spaces,
    /// not nothing, so the frame is still worth sending.
    func testTextThatIsAllStrippedBytesStillPastes() {
        XCTAssertEqual(
            BracketedPaste.payload("\u{1B}\u{0}"),
            Data("\u{1B}[200~  \u{1B}[201~".utf8)
        )
    }

    private func occurrences(of needle: Data, in haystack: Data) -> Int {
        guard !needle.isEmpty, haystack.count >= needle.count else { return 0 }
        let bytes = Array(haystack)
        let pattern = Array(needle)
        var count = 0
        for index in 0...(bytes.count - pattern.count) where Array(bytes[index..<(index + pattern.count)]) == pattern {
            count += 1
        }
        return count
    }
}
