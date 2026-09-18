import Foundation
import XCTest

/// `ChatToolLocator` globs a plugins tree with two wildcards
/// (`<install>/<plugin>/target/release/herdr-chat`), so these tests build one
/// under a temporary directory rather than touch the real `~/.config/herdr`.
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

    /// `/var` is a symlink to `/private/var` on this machine, and Foundation
    /// resolves it inconsistently between building a path here and walking
    /// one inside the locator. Comparing paths modulo that prefix is the
    /// actual test; a real difference in binary path still fails either form.
    private func assertSamePath(_ actual: String?, _ expected: String, line: UInt = #line) {
        func canonical(_ path: String) -> String {
            path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
        }
        XCTAssertEqual(actual.map(canonical), canonical(expected), line: line)
    }

    @discardableResult
    private func installBinary(
        at installKind: String, plugin: String, modified: Date = Date()
    ) throws -> URL {
        let directory = root
            .appendingPathComponent(installKind, isDirectory: true)
            .appendingPathComponent(plugin, isDirectory: true)
            .appendingPathComponent("target/release", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let binary = directory.appendingPathComponent("herdr-chat")
        FileManager.default.createFile(atPath: binary.path, contents: Data([0x00]))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755, .modificationDate: modified], ofItemAtPath: binary.path
        )
        return binary
    }

    func testAnOverrideWinsEvenWithAnInstallPresent() throws {
        try installBinary(at: "github", plugin: "m4ttstack.chat-abc123")
        XCTAssertEqual(
            ChatToolLocator.resolve(environmentOverride: "/opt/chat", pluginsDirectory: root),
            "/opt/chat"
        )
    }

    /// Both wildcards: the install-kind directory ("config" vs "github") and
    /// the plugin directory itself, which carries a build hash suffix.
    func testFindsTheBinaryThroughBothWildcards() throws {
        let binary = try installBinary(at: "github", plugin: "m4ttstack.chat-3fdefc4d82ce")
        assertSamePath(
            ChatToolLocator.resolve(environmentOverride: nil, pluginsDirectory: root), binary.path
        )
    }

    /// The real machine carries a "config" install with a same-named
    /// directory but no built, executable binary; only the executable counts.
    func testANonExecutableCandidateIsSkipped() throws {
        let directory = root
            .appendingPathComponent("config", isDirectory: true)
            .appendingPathComponent("m4ttstack.chat", isDirectory: true)
            .appendingPathComponent("target/release", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let binary = directory.appendingPathComponent("herdr-chat")
        FileManager.default.createFile(atPath: binary.path, contents: Data([0x00]))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: binary.path)
        XCTAssertNil(ChatToolLocator.resolve(environmentOverride: nil, pluginsDirectory: root))
    }

    func testTheNewestOfTwoInstallsWins() throws {
        try installBinary(
            at: "github", plugin: "m4ttstack.chat-oldbuild", modified: Date(timeIntervalSinceNow: -3600)
        )
        let newer = try installBinary(at: "github", plugin: "m4ttstack.chat-newbuild")
        assertSamePath(
            ChatToolLocator.resolve(environmentOverride: nil, pluginsDirectory: root), newer.path
        )
    }

    func testNoPluginsDirectoryAtAllIsAbsent() {
        let missing = root.appendingPathComponent("does-not-exist", isDirectory: true)
        XCTAssertNil(ChatToolLocator.resolve(environmentOverride: nil, pluginsDirectory: missing))
    }
}
