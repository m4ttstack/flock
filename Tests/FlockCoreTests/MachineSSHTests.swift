import XCTest
@testable import FlockCore

final class MachineSSHTests: XCTestCase {
    private let paths = MachineTunnelPaths(uid: 501, bundleTag: "dev", machineID: "0123456789abcdef0123456789abcdef")

    private func entry(_ name: String, running: Bool = true, isDefault: Bool = false) -> HerdrSessionEntry {
        HerdrSessionEntry(name: name, isRunning: running, socketPath: "/home/acme/\(name).sock", isDefault: isDefault)
    }

    func testForwardArgumentsCarryBothSocketsAndTheFixedOptions() {
        let args = MachineSSH.forwardArguments(target: "acme-mini", paths: paths,
            remoteAPISocket: "/Users/acme/.config/herdr/herdr.sock")
        XCTAssertEqual(Array(args.prefix(11)), ["-N", "-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes",
            "-o", "StreamLocalBindUnlink=yes", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3"])
        XCTAssertTrue(args.contains("/tmp/flock-501/dev-0123456789ab/herdr.sock:/Users/acme/.config/herdr/herdr.sock"))
        XCTAssertTrue(args.contains("/tmp/flock-501/dev-0123456789ab/herdr-client.sock:/Users/acme/.config/herdr/herdr-client.sock"))
        XCTAssertEqual(args.last, "acme-mini")
    }

    func testResolveScriptFallsBackToLocalBin() {
        let args = MachineSSH.resolveArguments(target: "acme-mini")
        let joined = args.joined(separator: " ")
        XCTAssertTrue(joined.contains("command -v herdr"))
        XCTAssertTrue(joined.contains("$HOME/.local/bin/herdr"))
        XCTAssertTrue(joined.contains("session list --json"))
        XCTAssertTrue(args.contains("BatchMode=yes"))
        XCTAssertEqual(args[args.count - 2], "acme-mini")
        XCTAssertTrue(args.last!.hasPrefix("sh -c '"))
    }

    func testRemoteSocketPicksNamedOrDefaultSession() throws {
        let entries = [entry("main", isDefault: true), entry("work")]
        XCTAssertEqual(try MachineSSH.remoteAPISocket(from: entries, session: "default"), "/home/acme/main.sock")
        XCTAssertEqual(try MachineSSH.remoteAPISocket(from: entries, session: "work"), "/home/acme/work.sock")
        XCTAssertThrowsError(try MachineSSH.remoteAPISocket(from: entries, session: "nope")) {
            XCTAssertEqual($0 as? MachineResolveError, .unknownSession)
        }
    }

    func testStoppedRemoteSessionThrowsNoServer() {
        let entries = [entry("main", running: false, isDefault: true)]
        XCTAssertThrowsError(try MachineSSH.remoteAPISocket(from: entries, session: "default")) {
            XCTAssertEqual($0 as? MachineResolveError, .noServer)
        }
    }

    func testRemoteClientSocketIsASibling() {
        XCTAssertEqual(MachineSSH.remoteClientSocket(apiSocket: "/Users/acme/.config/herdr/herdr.sock"),
                       "/Users/acme/.config/herdr/herdr-client.sock")
    }

    func testShellQuoteEscapesSingleQuotes() {
        XCTAssertEqual(MachineSSH.shellQuote("a'b"), "'a'\\''b'")
    }

    func testUploadArgumentsWriteIntoPasteDirectory() {
        let args = MachineSSH.uploadArguments(target: "acme-mini", remotePath: "/tmp/flock-paste/x.png")
        XCTAssertEqual(MachineSSH.remotePasteDirectory, "/tmp/flock-paste")
        XCTAssertTrue(args.contains("BatchMode=yes"))
        XCTAssertEqual(args[args.count - 2], "acme-mini")
        let cmd = args.last!
        XCTAssertTrue(cmd.hasPrefix("sh -c '"))
        XCTAssertTrue(cmd.contains("mkdir -p /tmp/flock-paste"))
        XCTAssertTrue(cmd.contains("cat > "))
        XCTAssertTrue(cmd.contains("x.png"))
    }
}
