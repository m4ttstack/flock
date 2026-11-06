import XCTest
@testable import FlockCore

final class FlockOpenLinkTests: XCTestCase {
    private func url(_ query: [String: String]) -> URL {
        var components = URLComponents(string: "flock://open")!
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url!
    }

    private let full = [
        "folder": "/trees/a b", "repo": "/repo", "label": "!12", "kind": "command", "run": "rt sync && echo \"ok\"",
        "token": "secret",
    ]

    private func parse(_ query: [String: String], token: String? = "secret", folders: Bool = true) -> Result<FlockOpenLink, FlockOpenLink.Refusal> {
        FlockOpenLink.parse(url(query), expectedToken: token, isFolder: { _ in folders })
    }

    func testAFullLinkParses() {
        XCTAssertEqual(
            try parse(full).get(),
            FlockOpenLink(folder: "/trees/a b", repo: "/repo", label: "!12", kind: .command, run: "rt sync && echo \"ok\"")
        )
    }

    func testAWrongOrMissingTokenIsRefused() {
        var wrong = full
        wrong["token"] = "nope"
        XCTAssertEqual(parse(wrong), .failure(.badToken))
        var none = full
        none["token"] = nil
        XCTAssertEqual(parse(none), .failure(.badToken))
        XCTAssertEqual(parse(full, token: nil), .failure(.badToken))
        XCTAssertEqual(parse(full, token: ""), .failure(.badToken))
    }

    func testOtherLinksAreNotOpenLinks() {
        XCTAssertEqual(
            FlockOpenLink.parse(URL(string: "flock://close?x=1")!, expectedToken: "secret", isFolder: { _ in true }),
            .failure(.notAnOpenLink)
        )
        XCTAssertFalse(FlockOpenLink.isOpenLink(URL(string: "https://open")!))
    }

    func testMissingFieldsUnknownKindsAndNonFoldersAreRefused() {
        var noLabel = full
        noLabel["label"] = nil
        XCTAssertEqual(parse(noLabel), .failure(.missing("label")))
        var badKind = full
        badKind["kind"] = "rm"
        XCTAssertEqual(parse(badKind), .failure(.unknownKind("rm")))
        XCTAssertEqual(parse(full, folders: false), .failure(.notAFolder("/trees/a b")))
        var noRun = full
        noRun["run"] = nil
        XCTAssertEqual(parse(noRun), .failure(.missing("command")))
    }

    func testAShellNeedsNoCommand() {
        var shell = full
        shell["kind"] = "shell"
        shell["run"] = nil
        XCTAssertEqual(try parse(shell).get().run, nil)
    }

    func testThePaneLineAppliesAPinsAccountToClaudeKindsOnly() {
        let claude = FlockOpenLink(folder: "/a", repo: "/r", label: "!1", kind: .claude, run: "claude")
        XCTAssertEqual(claude.paneLine(accountLine: nil), "claude")
        XCTAssertEqual(claude.paneLine(accountLine: "claude"), "claude")
        XCTAssertEqual(claude.paneLine(accountLine: "cswap run 2"), "cswap run 2")
        let resume = FlockOpenLink(folder: "/a", repo: "/r", label: "!1", kind: .resume, run: "claude --resume 'abc'")
        XCTAssertEqual(resume.paneLine(accountLine: "cswap run 2"), "cswap run 2 -- --resume 'abc'")
        let command = FlockOpenLink(folder: "/a", repo: "/r", label: "!1", kind: .command, run: "claude --x")
        XCTAssertEqual(command.paneLine(accountLine: "cswap run 2"), "claude --x")
        let shell = FlockOpenLink(folder: "/a", repo: "/r", label: "!1", kind: .shell, run: nil)
        XCTAssertNil(shell.paneLine(accountLine: "cswap run 2"))
    }

    func testThePinIsTheFirstSharingTheReposCommonDir() {
        func pin(_ name: String, _ folder: String) -> PinnedWorkspace {
            PinnedWorkspace(id: PinID(rawValue: name), name: name, folder: folder, workspace: nil, syncedLabel: nil, confirmed: false)
        }
        let dirs = ["/repo": "/repo/.git", "/trees/a": "/repo/.git", "/other": "/other/.git"]
        let pins = [pin("other", "/other"), pin("tree", "/trees/a"), pin("main", "/repo")]
        XCTAssertEqual(FlockOpenPinMatch.pin(for: "/repo", in: pins, commonDir: { dirs[$0] })?.name, "tree")
        XCTAssertNil(FlockOpenPinMatch.pin(for: "/nowhere", in: pins, commonDir: { dirs[$0] }))
    }

    func testTheTokenIsMadeOncePrivatelyAndReused() throws {
        let home = NSTemporaryDirectory() + "flock-token-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: home) }
        let first = try XCTUnwrap(FlockOpenToken.readOrCreate(home: home))
        XCTAssertEqual(first.count, 64)
        XCTAssertEqual(FlockOpenToken.readOrCreate(home: home), first)
        let attributes = try FileManager.default.attributesOfItem(atPath: FlockOpenToken.path(home: home))
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testATokenAlreadyThereIsNeverReplacedAndNoTempFileStays() throws {
        let home = NSTemporaryDirectory() + "flock-token-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: home) }
        let path = FlockOpenToken.path(home: home)
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        try Data("board-made\n".utf8).write(to: URL(fileURLWithPath: path))
        XCTAssertEqual(FlockOpenToken.readOrCreate(home: home), "board-made")
        let folder = (path as NSString).deletingLastPathComponent
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder), ["open-token"])
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
}
