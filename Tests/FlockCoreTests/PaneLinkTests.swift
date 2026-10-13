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

    func testAnAddressNoAppOpensIsNothing() {
        XCTAssertNil(resolve("x-man-page://ls", existing: []))
        XCTAssertNil(resolve("vscode://file/Users/acme/notes.md", existing: []))
    }

    func testAnAddressWithoutSlashesIsStillAnAddress() {
        let link = PaneLink.resolve("ssh:acme.example.com", folder: folder, home: home, handled: { _ in true }) { _ in false }
        XCTAssertEqual(link, .web(URL(string: "ssh:acme.example.com")!))
    }

    func testAnAddressSomeAppOpensIsALink() {
        let link = PaneLink.resolve("vscode://file/notes.md", folder: folder, home: home, handled: { $0.scheme == "vscode" }) { _ in
            false
        }
        XCTAssertEqual(link, .web(URL(string: "vscode://file/notes.md")!))
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

    // MARK: - An address on a row

    private let row = "open (vscode://file/Users/acme/notes.md:12) or zed://file/tmp/a.txt, then stop."

    func testTheAddressUnderTheColumnIsFound() {
        XCTAssertEqual(PaneLink.address(inRow: row, column: 6), "vscode://file/Users/acme/notes.md:12")
        XCTAssertEqual(PaneLink.address(inRow: row, column: 40), "vscode://file/Users/acme/notes.md:12")
        XCTAssertEqual(PaneLink.address(inRow: row, column: 50), "zed://file/tmp/a.txt")
    }

    func testTextAroundAnAddressIsNotOne() {
        XCTAssertNil(PaneLink.address(inRow: row, column: 0))
        XCTAssertNil(PaneLink.address(inRow: row, column: 5))
        XCTAssertNil(PaneLink.address(inRow: row, column: 42))
        XCTAssertNil(PaneLink.address(inRow: row, column: 75))
        XCTAssertNil(PaneLink.address(inRow: row, column: 500))
    }

    func testABracketTheAddressOpenedIsKept() {
        let wiki = "see https://example.com/wiki/Rust_(game)."
        XCTAssertEqual(PaneLink.address(inRow: wiki, column: 10), "https://example.com/wiki/Rust_(game)")
    }

    func testARowWithNoAddressHasNone() {
        XCTAssertNil(PaneLink.address(inRow: "Sources/main.swift:12 and ~/notes.md", column: 3))
        XCTAssertNil(PaneLink.address(inRow: "", column: 0))
    }

    // MARK: - A link on a row

    private func match(_ row: String, _ column: Int, existing: Set<String>) -> PaneLink.Match? {
        PaneLink.match(inRow: row, column: column, folder: folder, home: home, handled: { $0.scheme == "vscode" }) {
            existing.contains($0)
        }
    }

    /// libghostty reads the whole of this as one path.
    func testAPathEndsWhereTheCommandAfterItBegins() {
        let line = "~/Documents/src && git pull && bun run ui:build"
        let found = match(line, 4, existing: ["/Users/acme/Documents/src"])
        XCTAssertEqual(found, PaneLink.Match(link: file("/Users/acme/Documents/src"), columns: 0..<15))
        XCTAssertNil(match(line, 20, existing: ["/Users/acme/Documents/src"]))
    }

    /// The terminal counts cells, and a picture emoji is two of them.
    func testColumnsCountCellsNotCharacters() {
        let line = "\u{1F4A5} cd ~/Documents/src && git pull"
        let found = match(line, 7, existing: ["/Users/acme/Documents/src"])
        XCTAssertEqual(found?.columns, 6..<21)
        XCTAssertNil(match(line, 5, existing: ["/Users/acme/Documents/src"]))
        XCTAssertNil(match(line, 21, existing: ["/Users/acme/Documents/src"]))
    }

    func testWideTextIsTwoCellsACharacter() {
        XCTAssertEqual(PaneLink.cellWidth(of: "a"), 1)
        XCTAssertEqual(PaneLink.cellWidth(of: "\u{1F4A5}"), 2)
        XCTAssertEqual(PaneLink.cellWidth(of: "\u{6F22}"), 2)
        XCTAssertEqual(PaneLink.cellWidth(of: "\u{2713}"), 1)
    }

    func testAPathMayHoldSpaces() {
        let line = "see ~/Library/Application Support/acme/log.txt for more"
        let path = "/Users/acme/Library/Application Support/acme/log.txt"
        let found = match(line, 28, existing: [path])
        XCTAssertEqual(found, PaneLink.Match(link: file(path), columns: 4..<46))
    }

    func testTheLongestPathOnDiskWins() {
        let line = "/tmp/a b"
        XCTAssertEqual(match(line, 2, existing: ["/tmp/a", "/tmp/a b"])?.columns, 0..<8)
    }

    func testARelativePathIsOneWord() {
        let line = "- M3, first report: m3-exit/sheet.html (new)"
        let path = "/Users/acme/work/app/m3-exit/sheet.html"
        XCTAssertEqual(match(line, 25, existing: [path]), PaneLink.Match(link: file(path), columns: 20..<38))
    }

    func testAPositionAndBracketsAreOutsideThePath() {
        let line = "at (Sources/main.swift:12)."
        let path = "/Users/acme/work/app/Sources/main.swift"
        XCTAssertEqual(match(line, 10, existing: [path])?.columns, 4..<22)
        XCTAssertNil(match(line, 23, existing: [path]))
    }

    func testAPathThatIsNotOnDiskIsNoLink() {
        XCTAssertNil(match("~/gone/sheet.html and/or more", 3, existing: []))
        XCTAssertNil(match("~/gone/sheet.html and/or more", 20, existing: []))
    }

    func testASlashAloneIsNoLink() {
        XCTAssertNil(match("a / b // c", 2, existing: ["/"]))
        XCTAssertNil(match("a / b // c", 6, existing: ["/"]))
    }

    func testAnAddressInAnySchemeIsALink() {
        let line = "open vscode://file/tmp/x, then https://example.com."
        XCTAssertEqual(
            match(line, 8, existing: []),
            PaneLink.Match(link: .web(URL(string: "vscode://file/tmp/x")!), columns: 5..<24)
        )
        XCTAssertEqual(match(line, 35, existing: [])?.link, .web(URL(string: "https://example.com")!))
        XCTAssertNil(match("zed://file/tmp/x", 3, existing: []))
    }

    func testNothingHoveredIsNothing() {
        XCTAssertNil(resolve(nil, existing: []))
        XCTAssertNil(resolve("", existing: []))
        XCTAssertNil(resolve("   ", existing: []))
    }
}
