import XCTest
@testable import FlockCore

final class CopiedToastMessageTests: XCTestCase {
    func testSingleLineShowsAQuotedPreview() {
        XCTAssertEqual(CopiedToastMessage.make(for: "git status"), "Copied \u{201C}git status\u{201D}")
    }

    func testSingleLinePreviewIsTrimmed() {
        XCTAssertEqual(CopiedToastMessage.make(for: "   git status  \n"), "Copied \u{201C}git status\u{201D}")
    }

    func testLongSingleLineIsTruncatedWithAnEllipsis() {
        let line = String(repeating: "x", count: 40)
        let expected = "Copied \u{201C}" + String(repeating: "x", count: 24) + "\u{2026}\u{201D}"
        XCTAssertEqual(CopiedToastMessage.make(for: line), expected)
    }

    func testMultipleLinesShowACount() {
        XCTAssertEqual(CopiedToastMessage.make(for: "one\ntwo"), "Copied 2 lines")
        XCTAssertEqual(CopiedToastMessage.make(for: "one\ntwo\nthree"), "Copied 3 lines")
    }

    func testTrailingNewlinesDoNotInflateTheCount() {
        XCTAssertEqual(CopiedToastMessage.make(for: "one\ntwo\n\n"), "Copied 2 lines")
    }

    func testBlankOnlyTextIsJustCopied() {
        XCTAssertEqual(CopiedToastMessage.make(for: "   \n  "), "Copied")
    }
}
