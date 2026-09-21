import XCTest
@testable import FlockCore

/// Every path here is under a throwaway temp directory. Nothing in this file
/// may reference the owner's real `~/.local/bin/herdr`, and nothing runs a
/// herdr binary; the marker bytes stand in for it entirely.
final class HerdrMousePatchInstallerTests: XCTestCase {
    private var root: URL!
    private var binaryPath: String!
    private var artifactPath: String!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("flock-herdr-mouse-patch-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        binaryPath = root.appendingPathComponent("herdr").path
        artifactPath = root.appendingPathComponent("herdr-patched-artifact").path
        try Data("unpatched herdr build, no verbs here".utf8).write(to: URL(fileURLWithPath: binaryPath))
        try Data("patched herdr build carrying terminal.mouse".utf8).write(to: URL(fileURLWithPath: artifactPath))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var backupPath: String { HerdrMousePatchInstaller.backupPath(for: binaryPath) }

    // MARK: - install

    func testInstallBacksUpTheOriginalAndSwapsInTheArtifact() throws {
        try HerdrMousePatchInstaller.install(artifactPath: artifactPath, binaryPath: binaryPath)

        XCTAssertEqual(try String(contentsOfFile: backupPath, encoding: .utf8), "unpatched herdr build, no verbs here")
        XCTAssertEqual(
            try String(contentsOfFile: binaryPath, encoding: .utf8), "patched herdr build carrying terminal.mouse")
    }

    /// The staging file must be gone once install lands: nothing is left
    /// behind for a later probe to trip over.
    func testInstallLeavesNoStagingFileBehind() throws {
        try HerdrMousePatchInstaller.install(artifactPath: artifactPath, binaryPath: binaryPath)

        XCTAssertFalse(FileManager.default.fileExists(atPath: HerdrMousePatchInstaller.stagingPath(for: binaryPath)))
    }

    /// The rename step, not a copy-then-delete: a file descriptor opened on
    /// the old inode before install must still read the OLD content
    /// afterward, because the directory entry moved rather than the
    /// destination file being overwritten in place. This is the difference
    /// between "a running herdr keeps its open image" and a process that
    /// finds its own binary truncated out from under it.
    func testARunningReaderOfTheOldBinaryIsUndisturbedByInstall() throws {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: binaryPath))
        defer { try? handle.close() }

        try HerdrMousePatchInstaller.install(artifactPath: artifactPath, binaryPath: binaryPath)

        let stillOpenContent = try handle.readToEnd().map { String(decoding: $0, as: UTF8.self) }
        XCTAssertEqual(stillOpenContent, "unpatched herdr build, no verbs here")
    }

    /// Never overwrite a backup that is already there: it may be the one
    /// original copy of a binary that predates this session entirely.
    func testInstallRefusesToClobberAnExistingBackup() throws {
        try Data("an earlier, unrelated backup".utf8).write(to: URL(fileURLWithPath: backupPath))

        XCTAssertThrowsError(try HerdrMousePatchInstaller.install(artifactPath: artifactPath, binaryPath: binaryPath)) { error in
            XCTAssertEqual(error as? HerdrMousePatchInstaller.InstallError, .backupAlreadyExists)
        }
        XCTAssertEqual(try String(contentsOfFile: backupPath, encoding: .utf8), "an earlier, unrelated backup")
        XCTAssertEqual(try String(contentsOfFile: binaryPath, encoding: .utf8), "unpatched herdr build, no verbs here")
    }

    func testInstallFailsWhenTheArtifactIsUnreadable() throws {
        try FileManager.default.removeItem(atPath: artifactPath)

        XCTAssertThrowsError(try HerdrMousePatchInstaller.install(artifactPath: artifactPath, binaryPath: binaryPath)) { error in
            XCTAssertEqual(error as? HerdrMousePatchInstaller.InstallError, .sourceUnreadable)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupPath))
    }

    func testInstallFailsWhenTheDestinationDirectoryIsNotWritable() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path) }

        XCTAssertThrowsError(try HerdrMousePatchInstaller.install(artifactPath: artifactPath, binaryPath: binaryPath)) { error in
            XCTAssertEqual(error as? HerdrMousePatchInstaller.InstallError, .destinationNotWritable)
        }
    }

    /// A corrupt or mislabeled artifact must not verify: install rejects it
    /// rather than reporting success for a binary that does not actually
    /// carry the verbs.
    func testInstallFailsVerificationWhenTheArtifactDoesNotCarryTheMarker() throws {
        try Data("not actually patched".utf8).write(to: URL(fileURLWithPath: artifactPath))

        XCTAssertThrowsError(try HerdrMousePatchInstaller.install(artifactPath: artifactPath, binaryPath: binaryPath)) { error in
            XCTAssertEqual(error as? HerdrMousePatchInstaller.InstallError, .verificationFailed)
        }
    }

    // MARK: - revert

    func testRevertRestoresTheBackupAndRemovesIt() throws {
        try HerdrMousePatchInstaller.install(artifactPath: artifactPath, binaryPath: binaryPath)

        try HerdrMousePatchInstaller.revert(binaryPath: binaryPath)

        XCTAssertEqual(try String(contentsOfFile: binaryPath, encoding: .utf8), "unpatched herdr build, no verbs here")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupPath))
    }

    /// Revert is only ever a file move, so it must work with no prebuilt
    /// artifact anywhere on disk.
    func testRevertWorksWithNoArtifactPresentAtAll() throws {
        try HerdrMousePatchInstaller.install(artifactPath: artifactPath, binaryPath: binaryPath)
        try FileManager.default.removeItem(atPath: artifactPath)

        try HerdrMousePatchInstaller.revert(binaryPath: binaryPath)

        XCTAssertEqual(try String(contentsOfFile: binaryPath, encoding: .utf8), "unpatched herdr build, no verbs here")
    }

    func testRevertFailsWhenThereIsNoBackup() {
        XCTAssertThrowsError(try HerdrMousePatchInstaller.revert(binaryPath: binaryPath)) { error in
            XCTAssertEqual(error as? HerdrMousePatchInstaller.RevertError, .backupMissing)
        }
        XCTAssertEqual(try? String(contentsOfFile: binaryPath, encoding: .utf8), "unpatched herdr build, no verbs here")
    }

    func testRevertFailsWhenTheDestinationDirectoryIsNotWritable() throws {
        try HerdrMousePatchInstaller.install(artifactPath: artifactPath, binaryPath: binaryPath)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path) }

        XCTAssertThrowsError(try HerdrMousePatchInstaller.revert(binaryPath: binaryPath)) { error in
            XCTAssertEqual(error as? HerdrMousePatchInstaller.RevertError, .destinationNotWritable)
        }
    }

    // MARK: - probe

    func testProbeOfAPlainUnpatchedBinaryIsPatchableShaped() {
        let probe = HerdrMousePatchInstaller.probe(binaryPath: binaryPath)

        XCTAssertFalse(probe.hasVerbs)
        XCTAssertFalse(probe.hasBackup)
        XCTAssertTrue(probe.isWritable)
    }

    /// The owner's real machine, in miniature: verbs present, backup beside
    /// it.
    func testProbeAfterInstallShowsVerbsAndBackup() throws {
        try HerdrMousePatchInstaller.install(artifactPath: artifactPath, binaryPath: binaryPath)

        let probe = HerdrMousePatchInstaller.probe(binaryPath: binaryPath)

        XCTAssertTrue(probe.hasVerbs)
        XCTAssertTrue(probe.hasBackup)
    }

    func testProbeReportsVersionSupportFromTheBinarysOwnBytes() throws {
        try Data("herdr 0.9.1".utf8).write(to: URL(fileURLWithPath: binaryPath))
        XCTAssertTrue(HerdrMousePatchInstaller.probe(binaryPath: binaryPath).versionSupported)

        try Data("herdr 0.10.0".utf8).write(to: URL(fileURLWithPath: binaryPath))
        XCTAssertFalse(HerdrMousePatchInstaller.probe(binaryPath: binaryPath).versionSupported)
    }
}
