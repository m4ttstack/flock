import AppKit
import FlockCore
import XCTest

/// The AppKit half of the paste rule, driven over a pasteboard of this test's
/// own so the user's real clipboard is never touched or read.
final class PasteboardPasteTextTests: XCTestCase {
    private var pasteboard: NSPasteboard!
    private var staged: [String] = []

    override func setUp() {
        super.setUp()
        // A name of this test's own: a pasteboard released and recreated under
        // one name starts its change count over, and a change count is how a
        // clipboard's contents are recognized again.
        pasteboard = NSPasteboard(name: .init("dev.mattstack.flock.tests.paste.\(UUID().uuidString)"))
        pasteboard.clearContents()
    }

    override func tearDown() {
        for path in staged {
            try? FileManager.default.removeItem(atPath: path)
        }
        staged = []
        pasteboard.releaseGlobally()
        pasteboard = nil
        super.tearDown()
    }

    private func write(_ items: [NSPasteboardItem]) {
        pasteboard.clearContents()
        pasteboard.writeObjects(items)
    }

    private func imageItem(_ bytes: Data, type: NSPasteboard.PasteboardType = .png) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setData(bytes, forType: type)
        return item
    }

    /// The whole bug: a screenshot tool's clipboard carries a file URL and
    /// image data, and no plain-text flavor at all.
    func testAFileURLPastesAsItsEscapedPath() {
        pasteboard.clearContents()
        pasteboard.writeObjects([URL(fileURLWithPath: "/Users/matt/Screenshots/shot 1.png") as NSURL])
        XCTAssertEqual(pasteboard.pasteText(), "/Users/matt/Screenshots/shot\\ 1.png")
    }

    func testTwoFilesPasteAsTwoEscapedPathsOneSpaceApart() {
        pasteboard.clearContents()
        pasteboard.writeObjects([
            URL(fileURLWithPath: "/tmp/one file.png") as NSURL,
            URL(fileURLWithPath: "/tmp/two.png") as NSURL,
        ])
        XCTAssertEqual(pasteboard.pasteText(), "/tmp/one\\ file.png /tmp/two.png")
    }

    func testPlainTextPastesUnchanged() {
        pasteboard.clearContents()
        pasteboard.setString("ls *.txt", forType: .string)
        XCTAssertEqual(pasteboard.pasteText(), "ls *.txt")
    }

    /// A capture taken straight to the clipboard: bytes, and nothing on disk
    /// to point at.
    func testImageBytesPasteAsThePathTheyAreStagedAt() throws {
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x10, 0x11, 0x12])
        write([imageItem(bytes)])

        let text = try XCTUnwrap(pasteboard.pasteText())

        let path = text.replacingOccurrences(of: "\\", with: "")
        staged.append(path)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), bytes)
    }

    /// libghostty answers a program's OSC 52 read through the same clipboard
    /// read as the user's own paste, so a program asking in a loop must not
    /// write a copy of the user's screenshot for every ask.
    func testOneClipboardStagesOneFileHoweverOftenItIsRead() throws {
        write([imageItem(Data([0x89, 0x50, 0x20, 0x21]))])
        let before = try stagedFileCount()

        let first = try XCTUnwrap(pasteboard.pasteText())
        let second = try XCTUnwrap(pasteboard.pasteText())

        staged.append(first.replacingOccurrences(of: "\\", with: ""))
        XCTAssertEqual(first, second)
        XCTAssertEqual(try stagedFileCount(), before + 1)
    }

    func testANewClipboardStagesAFileOfItsOwn() throws {
        write([imageItem(Data([0x89, 0x50, 0x30]))])
        let first = try XCTUnwrap(pasteboard.pasteText())
        staged.append(first.replacingOccurrences(of: "\\", with: ""))

        let later = Data([0x89, 0x50, 0x31, 0x32])
        write([imageItem(later)])
        let second = try XCTUnwrap(pasteboard.pasteText())
        let path = second.replacingOccurrences(of: "\\", with: "")
        staged.append(path)

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), later)
    }

    func testAnEmptyClipboardPastesNothing() {
        pasteboard.clearContents()
        XCTAssertNil(pasteboard.pasteText())
        XCTAssertFalse(pasteboard.offersPasteText)
    }

    func testAClipboardOfNothingATerminalCanTakePastesNothing() {
        let item = NSPasteboardItem()
        item.setData(Data([0x01]), forType: .init("com.apple.webarchive"))
        write([item])
        XCTAssertNil(pasteboard.pasteText())
        XCTAssertFalse(pasteboard.offersPasteText)
    }

    /// What the menu asks. It used to ask whether a string flavor existed,
    /// which is exactly the question a screenshot clipboard answers no to.
    func testTheMenuSeesAFileOnlyClipboardAsPastable() {
        pasteboard.clearContents()
        pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/shot.png") as NSURL])
        XCTAssertNil(pasteboard.string(forType: .string), "a file URL alone offers no string flavor")
        XCTAssertTrue(pasteboard.offersPasteText)
    }

    func testTheMenuSeesAnImageOnlyClipboardAsPastable() {
        write([imageItem(Data([0x89, 0x50]))])
        XCTAssertTrue(pasteboard.offersPasteText)
    }

    /// Menu validation runs every time a menu opens, so asking whether a paste
    /// is possible must not leave a staged file behind for each ask.
    func testAskingWhetherAPasteIsPossibleStagesNothing() throws {
        write([imageItem(Data([0x89, 0x50]))])
        let before = try stagedFileCount()

        XCTAssertTrue(pasteboard.offersPasteText)

        XCTAssertEqual(try stagedFileCount(), before)
    }

    // MARK: - Pasting into a machine pane

    private actor Sent {
        var uploads: [(bytes: Data, path: String)] = []
        func add(_ bytes: Data, _ path: String) { uploads.append((bytes, path)) }
    }

    private func uploader(sent: Sent, failing: Bool = false) -> RemoteFileUploader {
        RemoteFileUploader(target: "acme-mini", label: "acme-mini") { bytes, path in
            if failing { throw RemoteFileUploader.Failure(detail: "no route") }
            await sent.add(bytes, path)
        }
    }

    @MainActor
    func testARemotePasteUploadsTheFileAndPastesItsPathOnTheMachine() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("acme remote \(UUID().uuidString).txt")
        try Data("hello".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        pasteboard.clearContents()
        pasteboard.writeObjects([file as NSURL])
        let sent = Sent()

        let outcome = await pasteboard.remotePasteText(uploader: uploader(sent: sent))

        let uploads = await sent.uploads
        XCTAssertEqual(uploads.count, 1)
        XCTAssertEqual(uploads.first?.bytes, Data("hello".utf8))
        let remote = try XCTUnwrap(uploads.first?.path)
        XCTAssertTrue(remote.hasPrefix("/tmp/flock-paste/"))
        XCTAssertTrue(remote.hasSuffix("-\(file.lastPathComponent)"))
        XCTAssertEqual(outcome, .text(ClipboardPaste.escape(remote)))
    }

    @MainActor
    func testARemotePasteOfImageBytesUploadsThemWithoutStagingLocally() async throws {
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x01])
        write([imageItem(bytes)])
        let before = try stagedFileCount()
        let sent = Sent()

        let outcome = await pasteboard.remotePasteText(uploader: uploader(sent: sent))

        let uploads = await sent.uploads
        XCTAssertEqual(uploads.first?.bytes, bytes)
        XCTAssertTrue(try XCTUnwrap(uploads.first?.path).hasSuffix("-clipboard.png"))
        XCTAssertEqual(outcome, .text(ClipboardPaste.escape(try XCTUnwrap(uploads.first?.path))))
        XCTAssertEqual(try stagedFileCount(), before)
    }

    @MainActor
    func testARemotePasteOfTextUploadsNothing() async {
        pasteboard.clearContents()
        pasteboard.setString("ls *.txt", forType: .string)
        let sent = Sent()

        let outcome = await pasteboard.remotePasteText(uploader: uploader(sent: sent))

        XCTAssertEqual(outcome, .text("ls *.txt"))
        let uploads = await sent.uploads
        XCTAssertTrue(uploads.isEmpty)
    }

    @MainActor
    func testAFailedRemoteUploadPastesNothingAndNamesTheMachine() async {
        write([imageItem(Data([0x89, 0x50]))])

        let outcome = await pasteboard.remotePasteText(uploader: uploader(sent: Sent(), failing: true))

        XCTAssertEqual(outcome, .failed("Couldn't copy that to acme-mini."))
    }

    /// Declares an image flavor and never supplies its bytes.
    private final class EmptyProvider: NSObject, NSPasteboardItemDataProvider {
        func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {}
    }

    @MainActor
    func testAnImageWhoseBytesCannotBeReadPastesNothingAndSaysSo() async {
        let provider = EmptyProvider()
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.png])
        write([item])
        let sent = Sent()

        let outcome = await pasteboard.remotePasteText(uploader: uploader(sent: sent))
        withExtendedLifetime(provider) {}

        XCTAssertEqual(outcome, .failed("Couldn't copy that to acme-mini."))
        let uploads = await sent.uploads
        XCTAssertTrue(uploads.isEmpty)
    }

    private func stagedFileCount() throws -> Int {
        let directory = ClipboardImageStaging.directory
        guard FileManager.default.fileExists(atPath: directory.path) else { return 0 }
        return try FileManager.default.contentsOfDirectory(atPath: directory.path).count
    }
}
