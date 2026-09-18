import AppKit
import XCTest

/// The AppKit half of the paste rule, driven over a pasteboard of this test's
/// own so the user's real clipboard is never touched or read.
final class PasteboardPasteTextTests: XCTestCase {
    private var pasteboard: NSPasteboard!
    private var staged: [String] = []

    override func setUp() {
        super.setUp()
        pasteboard = NSPasteboard(name: .init("dev.mattstack.flock.tests.paste"))
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

    private func stagedFileCount() throws -> Int {
        let directory = ClipboardImageStaging.directory
        guard FileManager.default.fileExists(atPath: directory.path) else { return 0 }
        return try FileManager.default.contentsOfDirectory(atPath: directory.path).count
    }
}
