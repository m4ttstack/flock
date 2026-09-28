import Foundation
import XCTest

/// Builds binaries under a temporary directory rather than touch the app
/// bundle or a real mattstack checkout.
final class ChatToolLocatorTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("flock-chat-tool-locator-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        root = nil
        super.tearDown()
    }

    private func binary(_ name: String, permissions: Int = 0o755) throws -> String {
        let url = root.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data([0x00]))
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        return url.path
    }

    private var missing: String { root.appendingPathComponent("nowhere").path }

    func testAnOverrideWinsOverTheDevPathAndTheBundledCopy() throws {
        let override = try binary("override")
        XCTAssertEqual(
            ChatToolLocator.resolve(
                environmentOverride: override, devPath: try binary("dev"), bundledPath: try binary("bundled")
            ),
            override
        )
    }

    func testTheDevPathWinsOverTheBundledCopy() throws {
        let dev = try binary("dev")
        XCTAssertEqual(
            ChatToolLocator.resolve(environmentOverride: nil, devPath: dev, bundledPath: try binary("bundled")),
            dev
        )
    }

    func testTheBundledCopyIsUsedWithNoDevPath() throws {
        let bundled = try binary("bundled")
        XCTAssertEqual(
            ChatToolLocator.resolve(environmentOverride: nil, devPath: nil, bundledPath: bundled),
            bundled
        )
    }

    /// A dev checkout that has not built herdr-chat yet.
    func testAnUnbuiltDevPathFallsThroughToTheBundledCopy() throws {
        let bundled = try binary("bundled")
        XCTAssertEqual(
            ChatToolLocator.resolve(environmentOverride: nil, devPath: missing, bundledPath: bundled),
            bundled
        )
    }

    func testAnOverrideAtAMissingPathFallsThrough() throws {
        let bundled = try binary("bundled")
        XCTAssertEqual(
            ChatToolLocator.resolve(environmentOverride: missing, devPath: nil, bundledPath: bundled),
            bundled
        )
    }

    func testANonExecutableFileIsSkipped() throws {
        let notExecutable = try binary("not-executable", permissions: 0o644)
        XCTAssertNil(ChatToolLocator.resolve(environmentOverride: nil, devPath: notExecutable, bundledPath: nil))
    }

    func testADirectoryIsSkipped() throws {
        let directory = root.appendingPathComponent("a-directory", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertNil(ChatToolLocator.resolve(environmentOverride: nil, devPath: directory.path, bundledPath: nil))
    }

    func testNothingBuiltAnywhereIsAbsent() {
        XCTAssertNil(ChatToolLocator.resolve(environmentOverride: nil, devPath: missing, bundledPath: missing))
    }

    /// The release app's Info.plist never carries the key, and a build that
    /// did not pass the setting leaves Xcode's unsubstituted variable or an
    /// empty string behind.
    func testTheDevPathIsReadOnlyWhenABuildWroteIt() {
        XCTAssertEqual(ChatToolLocator.devPath(in: ["FlockHerdrChatPath": "/repo/herdr-chat"]), "/repo/herdr-chat")
        XCTAssertNil(ChatToolLocator.devPath(in: ["FlockHerdrChatPath": ""]))
        XCTAssertNil(ChatToolLocator.devPath(in: ["FlockHerdrChatPath": "$(FLOCK_HERDR_CHAT_PATH)"]))
        XCTAssertNil(ChatToolLocator.devPath(in: [:]))
        XCTAssertNil(ChatToolLocator.devPath(in: nil))
    }
}
