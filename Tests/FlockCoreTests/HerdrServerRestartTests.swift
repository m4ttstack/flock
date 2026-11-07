import Darwin
import FlockCore
import Foundation
import XCTest

/// The probe reads this test process and a socket it listens on itself;
/// nothing here starts or connects to a herdr.
final class HerdrServerRestartTests: XCTestCase {
    private let installed = HerdrMousePatchRowState.installed(backupPath: "/tmp/herdr.flock-original")

    func testOnlyACurrentServerChangingPatchWithTheServerOnAnotherBinaryNeedsARestart() {
        XCTAssertTrue(HerdrServerRestart.isNeeded(state: installed, patchChangesServer: true, server: .other))
        XCTAssertFalse(HerdrServerRestart.isNeeded(state: installed, patchChangesServer: true, server: .onDisk))
        XCTAssertFalse(HerdrServerRestart.isNeeded(state: installed, patchChangesServer: true, server: .unknown))
        XCTAssertFalse(HerdrServerRestart.isNeeded(state: installed, patchChangesServer: false, server: .other))
        let others: [HerdrMousePatchRowState?] = [
            nil, .supportedByHerdr, .unsupportedVersion, .notWritable(installPath: "/tmp/herdr"),
            .patchable(installPath: "/tmp/herdr", version: "0.9.5"),
            .outdated(installPath: "/tmp/herdr", version: "0.9.5", release: "0.9.5-r2", backupPath: "/tmp/b"),
        ]
        for state in others {
            XCTAssertFalse(
                HerdrServerRestart.isNeeded(state: state, patchChangesServer: true, server: .other), "\(String(describing: state))"
            )
        }
    }

    func testOnlyTheHostThemeRevisionChangesTheServer() throws {
        let current = try XCTUnwrap(HerdrMousePatchCatalog.entry(for: "0.9.5", arch: .arm64))
        XCTAssertEqual(current.revision, 2)
        XCTAssertTrue(current.changesServer)
        XCTAssertFalse(try XCTUnwrap(HerdrMousePatchCatalog.entry(for: "0.9.4", arch: .arm64)).changesServer)
        let first = HerdrMousePatchCatalog.releases.first { $0.version == "0.9.5" && $0.revision == 1 }
        XCTAssertEqual(first?.changesServer, false)
    }

    func testAFailedHandoffQuotesHerdrsMessage() {
        XCTAssertEqual(
            HerdrServerRestart.failureReason(
                output: #"{"error":{"code":"unsupported_in_app_mode","message":"live handoff is only supported by the headless server"}}"#
            ),
            "herdr's server didn't restart: live handoff is only supported by the headless server."
        )
        XCTAssertEqual(HerdrServerRestart.failureReason(output: "timed out"), "herdr's server didn't restart: timed out.")
        XCTAssertEqual(HerdrServerRestart.failureReason(output: "\n"), HerdrServerRestart.failedFallback)
    }

    func testTheServerRestartCopySaysPanesKeepRunningAndTheManualWayEndsThem() {
        XCTAssertEqual(
            HerdrMousePatchCopy.restartDetail(for: .updated, restartsServer: true),
            "Restart herdr to finish; panes keep running."
        )
        XCTAssertEqual(HerdrMousePatchCopy.restartDetail(for: .updated), "Restart Flock so your panes pick it up.")
        XCTAssertEqual(
            HerdrMousePatchCopy.restartDetail(for: .herdrUpdated(.reinstalled), restartsServer: true),
            "Restart herdr to finish; panes keep running."
        )
        XCTAssertEqual(
            HerdrMousePatchCopy.restartDetail(for: .herdrUpdated(.reinstalling), restartsServer: true),
            "Reinstalling mouse support, then restart Flock so your panes reconnect."
        )
        XCTAssertEqual(HerdrMousePatchCopy.restartHeadline(for: .serverBehind), "herdr's server is on an older build")
        XCTAssertEqual(HerdrMousePatchCopy.restartDetail(for: .serverBehind), "Restarting it keeps your panes running.")
        XCTAssertTrue(HerdrMousePatchCopy.offersRestart(for: .serverBehind))
        XCTAssertEqual(HerdrMousePatchCopy.restartActionTitle(restartsServer: true), "Restart herdr")
        XCTAssertEqual(HerdrMousePatchCopy.restartActionTitle(restartsServer: false), "Restart Flock")
        XCTAssertTrue(HerdrMousePatchCopy.serverRestartConfirmation.message.contains("Shells and agents keep running."))
        XCTAssertTrue(
            HerdrMousePatchCopy.serverRestartFailure("herdr's server didn't restart.")
                .hasSuffix("That ends every pane's shell and agent.")
        )
    }

    func testAProcessRunsTheBinaryItWasStartedFromAndNoOther() throws {
        let ownExecutable = try XCTUnwrap(Self.executablePath(of: getpid()))
        XCTAssertEqual(HerdrServerBinary.compare(pid: getpid(), binaryPath: ownExecutable), .onDisk)

        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("flock-server-binary-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: copy) }
        try FileManager.default.copyItem(atPath: ownExecutable, toPath: copy.path)
        XCTAssertEqual(HerdrServerBinary.compare(pid: getpid(), binaryPath: copy.path), .other)

        XCTAssertEqual(HerdrServerBinary.compare(pid: getpid(), binaryPath: copy.path + "-missing"), .unknown)
    }

    func testTheProbeFindsTheProcessListeningOnTheSocket() throws {
        let ownExecutable = try XCTUnwrap(Self.executablePath(of: getpid()))
        let directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("fsb-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketPath = directory.appendingPathComponent("s.sock").path
        let listener = try Self.listen(at: socketPath)
        defer { Darwin.close(listener) }

        XCTAssertEqual(HerdrServerBinary.probe(socketPath: socketPath, binaryPath: ownExecutable), .onDisk)
        XCTAssertEqual(
            HerdrServerBinary.probe(socketPath: directory.appendingPathComponent("none.sock").path, binaryPath: ownExecutable),
            .unknown
        )
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func listen(at path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        bytes.withUnsafeBytes { raw in withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: raw) } }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard fd >= 0, bound == 0, Darwin.listen(fd, 4) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return fd
    }
}
