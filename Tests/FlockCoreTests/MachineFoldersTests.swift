import FlockCore
import XCTest

final class MachineFoldersTests: XCTestCase {
    func testParseSkipsLoginNoiseAndSortsNaturally() {
        let stdout = Data("welcome to acme\nflock-dir:/Users/acme\nflock-sub:code10\nflock-sub:Documents\nflock-sub:code2\n".utf8)
        XCTAssertEqual(
            MachineFolderListing.parse(stdout),
            MachineFolderListing(path: "/Users/acme", subfolders: ["code2", "code10", "Documents"])
        )
    }

    func testParseNeedsAnAbsolutePath() {
        XCTAssertNil(MachineFolderListing.parse(Data("flock-sub:a\n".utf8)))
        XCTAssertNil(MachineFolderListing.parse(Data("flock-dir:relative\n".utf8)))
    }

    func testParentAndChild() {
        XCTAssertEqual(MachineFolderListing.parent(of: "/Users/acme"), "/Users")
        XCTAssertEqual(MachineFolderListing.parent(of: "/Users"), "/")
        XCTAssertNil(MachineFolderListing.parent(of: "/"))
        XCTAssertEqual(MachineFolderListing.child("Users", of: "/"), "/Users")
        XCTAssertEqual(MachineFolderListing.child("code", of: "/Users/acme"), "/Users/acme/code")
    }

    func testFolderTravelsOnStdinNotTheCommandLine() {
        let path = "/Users/acme/it's \\ odd"
        XCTAssertEqual(MachineFolderListing.input(for: path), Data((path + "\n").utf8))
        XCTAssertEqual(MachineFolderListing.input(for: nil), Data("\n".utf8))
        XCTAssertFalse(MachineFolderListing.arguments(target: "mini").joined().contains("acme"))
        XCTAssertFalse(MachineFolderListing.script.contains("'"), "the script survives single quoting in any shell")
    }

    @MainActor
    func testBrowserListsAndDropsAStaleListing() async {
        let gate = AsyncStream<Void>.makeStream()
        let browser = MachineFolderBrowser { path in
            if path == "/slow" {
                for await _ in gate.stream { break }
                return MachineFolderListing(path: "/slow", subfolders: [])
            }
            return MachineFolderListing(path: path ?? "/Users/acme", subfolders: ["code"])
        }
        await browser.go(to: nil)
        XCTAssertEqual(browser.chosen, "/Users/acme")
        let slow = Task { await browser.go(to: "/slow") }
        await Task.yield()
        XCTAssertNil(browser.chosen, "nothing is chosen while a folder loads")
        await browser.open("code")
        gate.continuation.yield()
        await slow.value
        XCTAssertEqual(browser.chosen, "/Users/acme/code")
    }

    @MainActor
    func testBrowserReportsAMissingFolder() async {
        let browser = MachineFolderBrowser { _ in throw MachineFolderBrowser.NoSuchFolder() }
        await browser.go(to: "/nope")
        XCTAssertEqual(browser.state, .failed("/nope isn't a folder on the machine."))
        XCTAssertNil(browser.chosen)
    }
}
