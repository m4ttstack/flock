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
        let override = root.appendingPathComponent("override-chat")
        FileManager.default.createFile(atPath: override.path, contents: Data([0x00]))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: override.path)
        assertSamePath(
            ChatToolLocator.resolve(environmentOverride: override.path, pluginsDirectory: root),
            override.path
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

    /// A typo or a deleted binary must fall through to a real install rather
    /// than report chat present at a path nothing is at.
    func testAnOverrideAtAMissingPathFallsThroughToACandidate() throws {
        let installed = try installBinary(at: "github", plugin: "m4ttstack.chat-abc123")
        assertSamePath(
            ChatToolLocator.resolve(
                environmentOverride: root.appendingPathComponent("nowhere").path, pluginsDirectory: root
            ),
            installed.path
        )
    }

    /// A directory or an unbuilt file at the override path is the same failure
    /// as a missing one: present on disk, not runnable.
    func testAnOverrideAtANonExecutablePathFallsThroughToACandidate() throws {
        let installed = try installBinary(at: "github", plugin: "m4ttstack.chat-abc123")
        let notExecutable = root.appendingPathComponent("not-executable")
        FileManager.default.createFile(atPath: notExecutable.path, contents: Data([0x00]))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: notExecutable.path)
        assertSamePath(
            ChatToolLocator.resolve(environmentOverride: notExecutable.path, pluginsDirectory: root),
            installed.path
        )
    }
}
