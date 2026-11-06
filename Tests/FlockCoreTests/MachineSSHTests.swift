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

    private var pasteDirectoryName: String { "flock-paste-\(getuid())" }

    func testTheUploadScriptWritesPrivatelyAndPrintsThePath() throws {
        let tmp = try scratchDirectory()
        let result = try runUploadScript(fileName: "t1-it's a shot.png", tmpdir: tmp, input: Data("hello".utf8))

        XCTAssertEqual(result.status, 0)
        let expected = "\(tmp)/\(pasteDirectoryName)/t1-it's a shot.png"
        XCTAssertEqual(MachineSSH.uploadedPath(from: result.stdout), expected)
        XCTAssertEqual(FileManager.default.contents(atPath: expected), Data("hello".utf8))
        let dirMode = try FileManager.default.attributesOfItem(atPath: "\(tmp)/\(pasteDirectoryName)")[.posixPermissions] as? Int
        let fileMode = try FileManager.default.attributesOfItem(atPath: expected)[.posixPermissions] as? Int
        XCTAssertEqual(dirMode, 0o700)
        XCTAssertEqual(fileMode, 0o600)
    }

    func testTheUploadScriptReusesItsOwnDirectoryAndTightensIt() throws {
        let tmp = try scratchDirectory()
        let dir = "\(tmp)/\(pasteDirectoryName)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])

        let result = try runUploadScript(fileName: "t2-a.txt", tmpdir: tmp, input: Data("x".utf8))

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(MachineSSH.uploadedPath(from: result.stdout), "\(dir)/t2-a.txt")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: dir)[.posixPermissions] as? Int, 0o700)
    }

    func testTheUploadScriptRefusesASymlinkedDirectory() throws {
        let tmp = try scratchDirectory()
        let elsewhere = "\(tmp)/elsewhere"
        try FileManager.default.createDirectory(atPath: elsewhere, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(atPath: "\(tmp)/\(pasteDirectoryName)", withDestinationPath: elsewhere)

        let result = try runUploadScript(fileName: "t3-a.txt", tmpdir: tmp, input: Data("x".utf8))

        XCTAssertNotEqual(result.status, 0)
        XCTAssertNil(MachineSSH.uploadedPath(from: result.stdout))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: elsewhere), [])
    }

    func testTheUploadScriptRefusesAFileInTheDirectorysPlace() throws {
        let tmp = try scratchDirectory()
        FileManager.default.createFile(atPath: "\(tmp)/\(pasteDirectoryName)", contents: Data())

        let result = try runUploadScript(fileName: "t4-a.txt", tmpdir: tmp, input: Data("x".utf8))

        XCTAssertNotEqual(result.status, 0)
        XCTAssertNil(MachineSSH.uploadedPath(from: result.stdout))
    }

    func testTheUploadScriptNeverOverwritesAnExistingFile() throws {
        let tmp = try scratchDirectory()
        let dir = "\(tmp)/\(pasteDirectoryName)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        FileManager.default.createFile(atPath: "\(dir)/t5-a.txt", contents: Data("old".utf8))

        let result = try runUploadScript(fileName: "t5-a.txt", tmpdir: tmp, input: Data("new".utf8))

        XCTAssertNotEqual(result.status, 0)
        XCTAssertEqual(FileManager.default.contents(atPath: "\(dir)/t5-a.txt"), Data("old".utf8))
    }

    func testUploadedPathIsTheLastLineAfterAnyStartupNoise() {
        XCTAssertEqual(MachineSSH.uploadedPath(from: Data("welcome\r\n/tmp/flock-paste-501/t1-a b.png\n".utf8)),
                       "/tmp/flock-paste-501/t1-a b.png")
        XCTAssertNil(MachineSSH.uploadedPath(from: Data("welcome\n".utf8)))
        XCTAssertNil(MachineSSH.uploadedPath(from: Data()))
    }

    func testLastLineSkipsTrailingBlankLines() {
        let stderr = Data("Warning: Permanently added acme-mini\r\nPermission denied (publickey).\n\n  \n".utf8)
        XCTAssertEqual(MachineSSH.lastLine(of: stderr), "Permission denied (publickey).")
        XCTAssertNil(MachineSSH.lastLine(of: Data("\n \n".utf8)))
        XCTAssertNil(MachineSSH.lastLine(of: Data()))
    }
}
