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
        XCTAssertEqual(args.suffix(2), ["--", "acme-mini"])
    }

    func testResolveScriptFallsBackToLocalBin() {
        let args = MachineSSH.resolveArguments(target: "acme-mini")
        let joined = args.joined(separator: " ")
        XCTAssertTrue(joined.contains("command -v herdr"))
        XCTAssertTrue(joined.contains("$HOME/.local/bin/herdr"))
        XCTAssertTrue(joined.contains("session list --json"))
        XCTAssertTrue(args.contains("BatchMode=yes"))
        XCTAssertEqual(args[args.count - 3], "--")
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

    func testUploadArgumentsRunTheUploadScriptThroughSh() {
        let args = MachineSSH.uploadArguments(target: "acme-mini", fileName: "x.png")
        XCTAssertTrue(args.contains("BatchMode=yes"))
        XCTAssertEqual(args[args.count - 3], "--")
        XCTAssertEqual(args[args.count - 2], "acme-mini")
        XCTAssertEqual(args.last, "sh -c " + MachineSSH.shellQuote(MachineSSH.uploadScript(fileName: "x.png")))
    }

    // MARK: - The upload script, run by the local sh

    private func runUploadScript(fileName: String, tmpdir: String, input: Data) throws -> (status: Int32, stdout: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", MachineSSH.uploadScript(fileName: fileName)]
        process.environment = ["TMPDIR": tmpdir + "/", "PATH": "/usr/bin:/bin"]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        stdin.fileHandleForWriting.write(input)
        try stdin.fileHandleForWriting.close()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }

    private func scratchDirectory() throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("flock-ssh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.path
    }

    private func pasteDirectories(in tmp: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: tmp).filter { $0.hasPrefix("flock-paste.") }
    }

    func testTheUploadScriptWritesIntoANewPrivateDirectoryAndPrintsThePath() throws {
        let tmp = try scratchDirectory()
        let result = try runUploadScript(fileName: "t1-shot.png", tmpdir: tmp, input: Data("hello".utf8))

        XCTAssertEqual(result.status, 0)
        let directories = try pasteDirectories(in: tmp)
        XCTAssertEqual(directories.count, 1)
        let directory = "\(tmp)/\(try XCTUnwrap(directories.first))"
        let expected = "\(directory)/t1-shot.png"
        XCTAssertEqual(MachineSSH.uploadedPath(from: result.stdout), expected)
        XCTAssertEqual(FileManager.default.contents(atPath: expected), Data("hello".utf8))
        let dirMode = try FileManager.default.attributesOfItem(atPath: directory)[.posixPermissions] as? Int
        let fileMode = try FileManager.default.attributesOfItem(atPath: expected)[.posixPermissions] as? Int
        XCTAssertEqual(dirMode, 0o700)
        XCTAssertEqual(fileMode, 0o600)
    }

    func testEveryUploadGetsItsOwnDirectorySoNoneOverwritesAnother() throws {
        let tmp = try scratchDirectory()
        let first = try runUploadScript(fileName: "t2-a.txt", tmpdir: tmp, input: Data("one".utf8))
        let second = try runUploadScript(fileName: "t2-a.txt", tmpdir: tmp, input: Data("two".utf8))

        let firstPath = try XCTUnwrap(MachineSSH.uploadedPath(from: first.stdout))
        let secondPath = try XCTUnwrap(MachineSSH.uploadedPath(from: second.stdout))
        XCTAssertNotEqual(firstPath, secondPath)
        XCTAssertEqual(FileManager.default.contents(atPath: firstPath), Data("one".utf8))
        XCTAssertEqual(FileManager.default.contents(atPath: secondPath), Data("two".utf8))
        XCTAssertEqual(try pasteDirectories(in: tmp).count, 2)
    }

    func testTheUploadScriptFailsWithoutAPathWhenItCannotMakeADirectory() throws {
        let tmp = try scratchDirectory()
        let result = try runUploadScript(fileName: "t3-a.txt", tmpdir: "\(tmp)/missing", input: Data("x".utf8))

        XCTAssertNotEqual(result.status, 0)
        XCTAssertNil(MachineSSH.uploadedPath(from: result.stdout))
    }

    func testUploadedPathFollowsTheMarkerAfterAnyStartupNoise() {
        let noisy = Data("welcome\r\nlast login, no newlineflock-paste:/tmp/flock-paste.ab12/t1-a.png\n".utf8)
        XCTAssertEqual(MachineSSH.uploadedPath(from: noisy), "/tmp/flock-paste.ab12/t1-a.png")
        XCTAssertEqual(MachineSSH.uploadedPath(from: Data("flock-paste:/x/t1-a.png".utf8)), "/x/t1-a.png")
        XCTAssertNil(MachineSSH.uploadedPath(from: Data("welcome\n/tmp/t1-a.png\n".utf8)))
        XCTAssertNil(MachineSSH.uploadedPath(from: Data()))
    }

    func testLastLineSkipsTrailingBlankLines() {
        let stderr = Data("Warning: Permanently added acme-mini\r\nPermission denied (publickey).\n\n  \n".utf8)
        XCTAssertEqual(MachineSSH.lastLine(of: stderr), "Permission denied (publickey).")
        XCTAssertNil(MachineSSH.lastLine(of: Data("\n \n".utf8)))
        XCTAssertNil(MachineSSH.lastLine(of: Data()))
    }
}
