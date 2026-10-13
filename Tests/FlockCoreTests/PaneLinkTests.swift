import XCTest
@testable import FlockCore

/// What the text under a hovered link opens. A wrong answer here either opens
/// nothing on a click, or opens something the pane never printed.
final class PaneLinkTests: XCTestCase {
    private let home = "/Users/acme"
    private let folder = "/Users/acme/work/app"

    private func resolve(_ text: String?, folder: String? = "/Users/acme/work/app", existing: Set<String>) -> PaneLink? {
        PaneLink.resolve(text, folder: folder, home: home) { existing.contains($0) }
    }

    private func file(_ path: String) -> PaneLink {
        .file(URL(fileURLWithPath: path))
    }

    func testAWebAddressOpensAsIs() {
        XCTAssertEqual(resolve("https://example.com/a?b=1", existing: []), .web(URL(string: "https://example.com/a?b=1")!))
    }

    func testAMailAddressOpens() {
        XCTAssertEqual(resolve("mailto:sam@example.com", existing: []), .web(URL(string: "mailto:sam@example.com")!))
    }

    /// A program in the pane chooses what it prints, and a click must not
    /// let it choose which app that text is handed to.
    func testAnAddressForSomeOtherAppIsNothing() {
        XCTAssertNil(resolve("x-man-page://ls", existing: []))
        XCTAssertNil(resolve("vscode://file/Users/acme/notes.md", existing: []))
        XCTAssertNil(resolve("ssh://acme.example.com", existing: []))
    }

    func testTheSchemeIsReadWithoutRegardToCase() {
        XCTAssertEqual(resolve("HTTPS://example.com", existing: []), .web(URL(string: "HTTPS://example.com")!))
    }

    func testATildePathIsUnderHome() {
        let path = "/Users/acme/.cache/runs/sheet.html"
        XCTAssertEqual(resolve("~/.cache/runs/sheet.html", existing: [path]), file(path))
    }

    func testAnAbsolutePathIsItself() {
        XCTAssertEqual(resolve("/tmp/report.html", existing: ["/tmp/report.html"]), file("/tmp/report.html"))
    }

    func testARelativePathIsUnderThePaneFolder() {
        let path = "/Users/acme/work/app/Sources/main.swift"
        XCTAssertEqual(resolve("Sources/main.swift", existing: [path]), file(path))
        XCTAssertEqual(resolve("./Sources/main.swift", existing: [path]), file(path))
    }

    func testAParentRelativePathIsCollapsed() {
        let path = "/Users/acme/work/notes.md"
        XCTAssertEqual(resolve("../notes.md", existing: [path]), file(path))
    }

    func testARelativePathWithNoPaneFolderIsNothing() {
        XCTAssertNil(resolve("Sources/main.swift", folder: nil, existing: ["/Users/acme/work/app/Sources/main.swift"]))
    }

    func testALineAndColumnSuffixIsDropped() {
        let path = "/Users/acme/work/app/Sources/main.swift"
        XCTAssertEqual(resolve("Sources/main.swift:12", existing: [path]), file(path))
        XCTAssertEqual(resolve("Sources/main.swift:12:5", existing: [path]), file(path))
    }

    func testSentencePunctuationAfterAPathIsDropped() {
        let path = "/Users/acme/.cache/sheet.html"
        XCTAssertEqual(resolve("~/.cache/sheet.html.", existing: [path]), file(path))
        XCTAssertEqual(resolve("~/.cache/sheet.html),", existing: [path]), file(path))
    }

    /// The longest reading wins, so a file whose own name ends in a full stop
    /// or a number is not cut short.
    func testAnExistingPathIsNeverTrimmed() {
        let exact = "/tmp/build:2"
        XCTAssertEqual(resolve("/tmp/build:2", existing: [exact, "/tmp/build"]), file(exact))
    }

    func testAPathThatIsNotOnDiskIsNothing() {
        XCTAssertNil(resolve("~/gone/sheet.html", existing: []))
    }

    func testAFileAddressIsAFile() {
        XCTAssertEqual(resolve("file:///tmp/report.html", existing: ["/tmp/report.html"]), file("/tmp/report.html"))
        XCTAssertEqual(resolve("file:///tmp/report.html:12", existing: ["/tmp/report.html"]), file("/tmp/report.html"))
        XCTAssertEqual(resolve("file:///tmp/my%20report.html.", existing: ["/tmp/my report.html"]), file("/tmp/my report.html"))
    }

    /// `URL(string:)` reads `main.swift:12` as an address with the scheme
    /// `main.swift`.
    func testAFileNameWithALineNumberIsNotAnAddress() {
        let path = "/Users/acme/work/app/main.swift"
        XCTAssertEqual(resolve("main.swift:12", existing: [path]), file(path))
    }

    func testNothingHoveredIsNothing() {
        XCTAssertNil(resolve(nil, existing: []))
        XCTAssertNil(resolve("", existing: []))
        XCTAssertNil(resolve("   ", existing: []))
    }
}
