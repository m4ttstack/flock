import XCTest
@testable import FlockCore

/// The rule in one line: a file URL pastes as its escaped path, anything else
/// with a string pastes that string, and image bytes with no file behind them
/// get one.
final class ClipboardPasteTests: XCTestCase {
    // MARK: - The rule, item by item

    /// The bug this rule exists for: a screenshot tool's clipboard carries a
    /// file URL and image data and no plain-text flavor at all, so reading
    /// `.string` finds nothing and the paste lands empty.
    func testAFileURLPastesAsItsEscapedPath() {
        let item = PasteboardItemDescription(
            fileURLPath: "/Users/matt/Screenshots/CleanShot 2026-09-18 at 8.20.00 AM.png",
            string: nil,
            typeIdentifiers: ["public.file-url", "public.png", "public.tiff"]
        )
        XCTAssertEqual(
            ClipboardPaste.decide(item),
            .text("/Users/matt/Screenshots/CleanShot\\ 2026-09-18\\ at\\ 8.20.00\\ AM.png")
        )
    }

    func testAFileURLOutranksTheItemsOwnString() {
        let item = PasteboardItemDescription(
            fileURLPath: "/tmp/shot.png",
            string: "file:///tmp/shot.png",
            typeIdentifiers: ["public.file-url", "public.utf8-plain-text"]
        )
        XCTAssertEqual(ClipboardPaste.decide(item), .text("/tmp/shot.png"))
    }

    /// Only a path is escaped. Text the user copied is pasted byte for byte,
    /// backslashes and all.
    func testAStringPastesUnchanged() {
        let item = PasteboardItemDescription(
            string: "echo 'hello world' && ls *.txt",
            typeIdentifiers: ["public.utf8-plain-text"]
        )
        XCTAssertEqual(ClipboardPaste.decide(item), .text("echo 'hello world' && ls *.txt"))
    }

    func testAnEmptyFileURLPathFallsThroughToTheString() {
        let item = PasteboardItemDescription(
            fileURLPath: "",
            string: "plain",
            typeIdentifiers: ["public.utf8-plain-text"]
        )
        XCTAssertEqual(ClipboardPaste.decide(item), .text("plain"))
    }

    /// A screen capture taken straight to the clipboard: bytes, no file, no
    /// string. Ghostty pastes nothing here; flock stages the bytes so there is
    /// a path to paste.
    func testImageBytesWithNoFileBehindThemAreStaged() {
        let item = PasteboardItemDescription(typeIdentifiers: ["public.png", "public.tiff"])
        XCTAssertEqual(
            ClipboardPaste.decide(item),
            .stageImage(typeIdentifier: "public.png", fileExtension: "png")
        )
    }

    func testPNGIsPreferredWhateverOrderTheItemOffersItsTypes() {
        let item = PasteboardItemDescription(typeIdentifiers: ["public.tiff", "public.jpeg", "public.png"])
        XCTAssertEqual(
            ClipboardPaste.decide(item),
            .stageImage(typeIdentifier: "public.png", fileExtension: "png")
        )
    }

    func testAnItemOfferingOnlyTIFFStagesAsTIFF() {
        let item = PasteboardItemDescription(typeIdentifiers: ["public.tiff"])
        XCTAssertEqual(
            ClipboardPaste.decide(item),
            .stageImage(typeIdentifier: "public.tiff", fileExtension: "tiff")
        )
    }

    func testEachStageableImageTypeCarriesItsOwnExtension() {
        let expected: [(String, String)] = [
            ("public.jpeg", "jpg"),
            ("public.gif", "gif"),
            ("com.microsoft.bmp", "bmp"),
            ("org.webmproject.webp", "webp"),
        ]
        for (identifier, fileExtension) in expected {
            XCTAssertEqual(
                ClipboardPaste.decide(PasteboardItemDescription(typeIdentifiers: [identifier])),
                .stageImage(typeIdentifier: identifier, fileExtension: fileExtension),
                "\(identifier) should stage as .\(fileExtension)"
            )
        }
    }

    func testAStringOutranksImageBytes() {
        let item = PasteboardItemDescription(
            string: "already text",
            typeIdentifiers: ["public.utf8-plain-text", "public.png"]
        )
        XCTAssertEqual(ClipboardPaste.decide(item), .text("already text"))
    }

    func testAnItemHoldingNothingATerminalCanTakeContributesNothing() {
        let item = PasteboardItemDescription(typeIdentifiers: ["com.apple.webarchive", "public.rtf"])
        XCTAssertEqual(ClipboardPaste.decide(item), .nothing)
    }

    func testAnItemWithNoTypesAtAllContributesNothing() {
        XCTAssertEqual(ClipboardPaste.decide(PasteboardItemDescription()), .nothing)
    }

    // MARK: - The whole clipboard

    func testThePlanKeepsTheClipboardsOwnItemOrder() {
        let items = [
            PasteboardItemDescription(fileURLPath: "/tmp/a b.png", typeIdentifiers: ["public.file-url"]),
            PasteboardItemDescription(typeIdentifiers: ["public.png"]),
            PasteboardItemDescription(string: "tail"),
        ]
        XCTAssertEqual(
            ClipboardPaste.plan(for: items),
            [
                .text("/tmp/a\\ b.png"),
                .stageImage(typeIdentifier: "public.png", fileExtension: "png"),
                .text("tail"),
            ]
        )
    }

    func testAnEmptyClipboardYieldsNoPasteAtAll() {
        XCTAssertNil(ClipboardPaste.text(joining: []))
    }

    func testEveryItemsTextJoinsWithASingleSpace() {
        XCTAssertEqual(
            ClipboardPaste.text(joining: ["/tmp/one.png", "/tmp/two.png"]),
            "/tmp/one.png /tmp/two.png"
        )
    }

    func testOneItemJoinsToItself() {
        XCTAssertEqual(ClipboardPaste.text(joining: ["solo"]), "solo")
    }

    // MARK: - Escaping

    /// A path holding spaces is the normal case for a screenshot, not an edge
    /// one: an unescaped one arrives at the shell as several words.
    func testASpaceInAPathIsEscaped() {
        XCTAssertEqual(ClipboardPaste.escape("/tmp/my file.png"), "/tmp/my\\ file.png")
    }

    /// Ghostty's own escape vectors. flock's panes are ghostty surfaces, so a
    /// path has to escape identically in both or the same clipboard pastes two
    /// different things.
    func testEscapingMatchesGhosttysCharacterSet() {
        let vectors: [(String, String)] = [
            ("hello", "hello"),
            ("", ""),
            ("file name", "file\\ name"),
            ("a\\b", "a\\\\b"),
            ("(foo)", "\\(foo\\)"),
            ("[bar]", "\\[bar\\]"),
            ("{baz}", "\\{baz\\}"),
            ("<qux>", "\\<qux\\>"),
            ("say\"hi\"", "say\\\"hi\\\""),
            ("it's", "it\\'s"),
            ("`cmd`", "\\`cmd\\`"),
            ("wow!", "wow\\!"),
            ("#comment", "\\#comment"),
            ("$HOME", "\\$HOME"),
            ("a&b", "a\\&b"),
            ("a;b", "a\\;b"),
            ("a|b", "a\\|b"),
            ("*.txt", "\\*.txt"),
            ("file?.log", "file\\?.log"),
            ("col1\tcol2", "col1\\\tcol2"),
            ("$(echo 'hi')", "\\$\\(echo\\ \\'hi\\'\\)"),
            ("/tmp/my file (1).txt", "/tmp/my\\ file\\ \\(1\\).txt"),
        ]
        for (input, expected) in vectors {
            XCTAssertEqual(ClipboardPaste.escape(input), expected, "escaping \(input)")
        }
    }

    /// Escaping is one pass, so a backslash the escape itself added is never
    /// escaped again.
    func testAnAlreadyBackslashedSpaceEscapesOnlyOnce() {
        XCTAssertEqual(ClipboardPaste.escape("a\\ b"), "a\\\\\\ b")
    }

    func testANewlineInAPathIsLeftAlone() {
        XCTAssertEqual(ClipboardPaste.escape("a\nb"), "a\nb")
    }

    // MARK: - Remote machine panes

    func testRemotePlanUploadsFileURLsInsteadOfPastingLocalPaths() {
        let item = PasteboardItemDescription(
            fileURLPath: "/Users/acme/shot.png", string: nil, typeIdentifiers: ["public.file-url"]
        )
        XCTAssertEqual(ClipboardPaste.remotePlan(for: [item]), [.uploadFile(localPath: "/Users/acme/shot.png")])
    }

    func testRemotePlanUploadsBareImageBytes() {
        let item = PasteboardItemDescription(typeIdentifiers: ["public.tiff", "public.png"])
        XCTAssertEqual(
            ClipboardPaste.remotePlan(for: [item]),
            [.uploadImage(typeIdentifier: "public.png", fileExtension: "png")]
        )
    }

    func testRemotePlanKeepsPlainText() {
        let item = PasteboardItemDescription(string: "ls -la", typeIdentifiers: ["public.utf8-plain-text"])
        XCTAssertEqual(ClipboardPaste.remotePlan(for: [item]), [.text("ls -la")])
    }

    func testRemotePlanSkipsWhatATerminalCannotTake() {
        XCTAssertEqual(ClipboardPaste.remotePlan(for: [PasteboardItemDescription()]), [.nothing])
    }

    func testRemoteFileNameIsPrefixedWithTheToken() {
        XCTAssertEqual(ClipboardPaste.remoteFileName("shot-1_v2+final.png", token: "ab12"), "ab12-shot-1_v2+final.png")
    }

    /// fish reads `\'` inside single quotes as a quote, so a name carrying
    /// one could close the remote script's quoting.
    func testRemoteFileNameKeepsOnlyShellNeutralCharacters() {
        XCTAssertEqual(ClipboardPaste.remoteFileName("a\\'; touch pwn; #\nb é.png", token: "ab12"),
                       "ab12-a____touch_pwn____b__.png")
    }

    // MARK: - Resolving a remote paste

    /// Stands in for the machine, which chooses the directory.
    private static let remoteDirectory = "/var/acme/paste dir"

    private actor Uploads {
        var sent: [(size: Int, name: String)] = []
        var failOn: Int?
        func record(_ data: Data, _ name: String) throws -> String {
            if sent.count + 1 == failOn { throw UploadFailure() }
            sent.append((data.count, name))
            return "\(ClipboardPasteTests.remoteDirectory)/\(name)"
        }
        func fail(on index: Int) { failOn = index }
    }

    private struct UploadFailure: Error {}

    private func resolve(_ entries: [RemotePasteEntry], uploads: Uploads) async -> RemotePasteOutcome {
        var tokens = ["t1", "t2", "t3"]
        return await RemotePaste.resolve(
            entries, label: "acme-mini",
            token: { tokens.removeFirst() },
            readFile: { _ in Data(repeating: 1, count: 7) },
            upload: { data, name in try await uploads.record(data, name) }
        )
    }

    func testAFilePastesTheEscapedPathTheMachineReported() async {
        let uploads = Uploads()
        let outcome = await resolve([.file(localPath: "/Users/acme/my shot.png")], uploads: uploads)
        XCTAssertEqual(outcome, .text("/var/acme/paste\\ dir/t1-my_shot.png"))
        let sent = await uploads.sent
        XCTAssertEqual(sent.map(\.name), ["t1-my_shot.png"])
        XCTAssertEqual(sent.map(\.size), [7])
    }

    func testImageBytesUploadUnderAClipboardName() async {
        let uploads = Uploads()
        let outcome = await resolve([.image(Data(count: 3), fileExtension: "png")], uploads: uploads)
        XCTAssertEqual(outcome, .text("/var/acme/paste\\ dir/t1-clipboard.png"))
        let sent = await uploads.sent
        XCTAssertEqual(sent.map(\.size), [3])
    }

    func testMixedItemsJoinWithASpaceInOrder() async {
        let uploads = Uploads()
        let outcome = await resolve(
            [.text("cat"), .file(localPath: "/a/one.txt"), .file(localPath: "/b/two.txt")], uploads: uploads
        )
        XCTAssertEqual(outcome, .text("cat /var/acme/paste\\ dir/t1-one.txt /var/acme/paste\\ dir/t2-two.txt"))
    }

    func testAFailedUploadPastesNothingEvenWhenAnEarlierOneLanded() async {
        let uploads = Uploads()
        await uploads.fail(on: 2)
        let outcome = await resolve([.file(localPath: "/a/one.txt"), .file(localPath: "/b/two.txt")], uploads: uploads)
        XCTAssertEqual(outcome, .failed("Couldn't copy that to acme-mini."))
    }

    func testAnUnreadableFileFails() async {
        let outcome = await RemotePaste.resolve(
            [.file(localPath: "/gone")], label: "acme-mini", token: { "t1" },
            readFile: { _ in throw UploadFailure() }, upload: { _, name in name }
        )
        XCTAssertEqual(outcome, .failed("Couldn't copy that to acme-mini."))
    }

    func testNoEntriesPasteNothing() async {
        let uploads = Uploads()
        let outcome = await resolve([], uploads: uploads)
        XCTAssertEqual(outcome, .nothing)
    }
}
