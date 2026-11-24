import XCTest

@testable import FlockCore

/// Every path is under a throwaway temp directory; fake binaries are byte
/// files and nothing runs a herdr.
final class HerdrBuildInstallerTests: XCTestCase {
    private var root: URL!
    private var artifactPath: String!
    private let artifactBytes = Data("herdr 0.9.5-ms.1 build".utf8)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("flock-herdr-build-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        artifactPath = root.appendingPathComponent("artifact").path
        try artifactBytes.write(to: URL(fileURLWithPath: artifactPath))
    }

    override func tearDownWithError() throws {
        chmod(root.appendingPathComponent("locked").path, 0o755)
        chmod(root.appendingPathComponent("unreadable/herdr").path, 0o644)
        try? FileManager.default.removeItem(at: root)
    }

    private var sha: String { (try? HerdrBuildDownloader.sha256(ofFileAt: URL(fileURLWithPath: artifactPath))) ?? "" }

    func testInstallCreatesMissingDirectory() throws {
        let binary = root.appendingPathComponent("home/.local/bin/herdr").path
        try HerdrBuildInstaller.install(artifactPath: artifactPath, binaryPath: binary, sha256: sha)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: binary)), artifactBytes)
        let mode = try FileManager.default.attributesOfItem(atPath: binary)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o755)
    }

    func testReplacesWithoutBackup() throws {
        let dir = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let binary = dir.appendingPathComponent("herdr").path
        try Data("old".utf8).write(to: URL(fileURLWithPath: binary))
        try HerdrBuildInstaller.install(artifactPath: artifactPath, binaryPath: binary, sha256: sha)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: binary)), artifactBytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["herdr"])
    }

    func testMismatchedArtifactLeavesBinaryAlone() throws {
        let dir = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let binary = dir.appendingPathComponent("herdr").path
        try Data("old".utf8).write(to: URL(fileURLWithPath: binary))
        XCTAssertThrowsError(
            try HerdrBuildInstaller.install(artifactPath: artifactPath, binaryPath: binary, sha256: String(repeating: "0", count: 64))
        ) { XCTAssertEqual($0 as? HerdrBuildInstaller.InstallError, .checksumMismatch) }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: binary)), Data("old".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["herdr"])
    }

    func testUnwritableDirectoryThrows() throws {
        let dir = root.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        chmod(dir.path, 0o555)
        XCTAssertThrowsError(
            try HerdrBuildInstaller.install(artifactPath: artifactPath, binaryPath: dir.appendingPathComponent("herdr").path, sha256: sha)
        ) { XCTAssertEqual($0 as? HerdrBuildInstaller.InstallError, .destinationNotWritable) }
    }

    func testUnreadableArtifactThrows() {
        XCTAssertThrowsError(
            try HerdrBuildInstaller.install(
                artifactPath: root.appendingPathComponent("nope").path, binaryPath: root.appendingPathComponent("herdr").path,
                sha256: sha)
        ) { XCTAssertEqual($0 as? HerdrBuildInstaller.InstallError, .sourceUnreadable) }
    }

    func testProbeOfMissingBinary() {
        var asked = false
        let probe = HerdrBuildInstaller.probe(
            binaryPath: root.appendingPathComponent("home/.local/bin/herdr").path,
            readVersionOutput: { _ in asked = true; return nil })
        XCTAssertEqual(probe, HerdrBuildInstaller.Probe(exists: false, isWritable: true, version: nil, sha256: nil))
        XCTAssertFalse(asked)
    }

    func testProbeReadsVersionAndSha() throws {
        let probe = HerdrBuildInstaller.probe(binaryPath: artifactPath, readVersionOutput: { _ in "herdr 0.9.5-ms.1\n" })
        XCTAssertTrue(probe.exists)
        XCTAssertEqual(probe.version, HerdrBuildVersion("0.9.5-ms.1"))
        XCTAssertEqual(probe.sha256, sha)
    }

    func testStagingFailureCleansUpAndKeepsTheOldBinary() throws {
        let dir = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let binary = dir.appendingPathComponent("herdr").path
        try Data("old".utf8).write(to: URL(fileURLWithPath: binary))
        let artifact = root.appendingPathComponent("artifact-dir")
        try FileManager.default.createDirectory(at: artifact, withIntermediateDirectories: true)
        let inner = artifact.appendingPathComponent("inner")
        try Data("x".utf8).write(to: inner)
        chmod(inner.path, 0o000)
        XCTAssertThrowsError(try HerdrBuildInstaller.install(artifactPath: artifact.path, binaryPath: binary, sha256: sha)) {
            XCTAssertEqual($0 as? HerdrBuildInstaller.InstallError, .stagingFailed)
        }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: binary)), Data("old".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["herdr"])
    }

    func testProbeOfUnreadableBinaryStillExists() throws {
        let dir = root.appendingPathComponent("unreadable")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let binary = dir.appendingPathComponent("herdr").path
        try Data("x".utf8).write(to: URL(fileURLWithPath: binary))
        chmod(binary, 0o000)
        var asked = false
        let probe = HerdrBuildInstaller.probe(binaryPath: binary, readVersionOutput: { _ in asked = true; return "herdr 0.9.5\n" })
        XCTAssertTrue(probe.exists)
        XCTAssertNil(probe.sha256)
        XCTAssertNil(probe.version)
        XCTAssertFalse(asked)
    }

    func testInstalledBinaryCarriesNoQuarantine() throws {
        let value = Array("0081;00000000;Safari;".utf8)
        XCTAssertEqual(setxattr(artifactPath, "com.apple.quarantine", value, value.count, 0, 0), 0)
        let binary = root.appendingPathComponent("bin/herdr").path
        try HerdrBuildInstaller.install(artifactPath: artifactPath, binaryPath: binary, sha256: sha)
        XCTAssertEqual(getxattr(binary, "com.apple.quarantine", nil, 0, 0, 0), -1)
        XCTAssertEqual(errno, ENOATTR)
    }

    func testFileName() throws {
        XCTAssertEqual(
            HerdrBuildInstaller.fileName(for: try XCTUnwrap(HerdrBuildVersion("0.9.5-ms.1")), arch: .x86_64), "herdr-0.9.5-ms.1-x86_64")
    }
}
