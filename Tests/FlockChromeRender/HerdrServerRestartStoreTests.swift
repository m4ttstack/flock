import CryptoKit
import FlockCore
import Foundation
import XCTest

/// The server probe and the handoff are both stubbed: nothing here connects
/// to a herdr, runs one, or relaunches anything.
@MainActor
final class HerdrServerRestartStoreTests: XCTestCase {
    nonisolated(unsafe) private var root: URL!
    nonisolated(unsafe) private var binaryPath: String!

    private let patched = Data("herdr 0.9.5 terminal.mouse_capture host_theme build".utf8)
    private let olderRevision = Data("herdr 0.9.5 terminal.mouse_capture older revision".utf8)

    private final class FileTransport: HerdrPatchTransport, @unchecked Sendable {
        let body: Data
        init(body: Data) { self.body = body }
        func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
            try body.write(to: destination)
        }
    }

    private final class StubRunner: HerdrCommandRunner, @unchecked Sendable {
        var calls: [[String]] = []
        let status: Int32
        let output: String
        init(status: Int32 = 0, output: String = "live handoff complete; server log: /tmp/herdr-server.log\n") {
            self.status = status
            self.output = output
        }
        func run(_ executable: String, _ arguments: [String]) async -> (status: Int32, output: String) {
            calls.append([executable] + arguments)
            return (status, output)
        }
    }

    private final class ServerStub: @unchecked Sendable {
        private let lock = NSLock()
        private var answer: HerdrServerBinary
        private(set) var asked: [String] = []
        init(_ answer: HerdrServerBinary) { self.answer = answer }
        func set(_ value: HerdrServerBinary) { lock.withLock { answer = value } }
        func probe(socket: String, binary: String) -> HerdrServerBinary {
            lock.withLock {
                asked.append(socket)
                return answer
            }
        }
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("flock-server-restart-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        binaryPath = root.appendingPathComponent("herdr").path
        try Data("herdr 0.9.5 unpatched build".utf8).write(to: URL(fileURLWithPath: binaryPath))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func installOlderRevision() throws {
        try FileManager.default.copyItem(atPath: binaryPath, toPath: HerdrMousePatchInstaller.backupPath(for: binaryPath))
        try olderRevision.write(to: URL(fileURLWithPath: binaryPath))
    }

    private func installCurrentRevision() throws {
        try FileManager.default.copyItem(atPath: binaryPath, toPath: HerdrMousePatchInstaller.backupPath(for: binaryPath))
        try patched.write(to: URL(fileURLWithPath: binaryPath))
    }

    private func makeStore(
        server: ServerStub, socket: String? = "/tmp/acme/herdr.sock", changesServer: Bool = true,
        runner: StubRunner = StubRunner(), relaunched: (() -> Void)? = nil
    ) -> HerdrMousePatchStore {
        let sha = Self.sha256(patched)
        let superseded: Set<String> = [Self.sha256(olderRevision)]
        return HerdrMousePatchStore(
            resolveBinaryPath: { [binaryPath] in binaryPath },
            catalog: {
                HerdrMousePatchEntry(
                    version: $0, sha256: sha, revision: 2, superseded: superseded, changesServer: changesServer
                )
            },
            downloader: HerdrMousePatchDownloader(
                cacheDirectory: root.appendingPathComponent("cache"), transport: FileTransport(body: patched)
            ),
            readVersionOutput: HerdrVersionFixture.read,
            serverSocketPath: { socket },
            probeServer: { server.probe(socket: $0, binary: $1) },
            runner: runner,
            relaunch: relaunched ?? { XCTFail("relaunched") }
        )
    }

    private func settle(_ store: HerdrMousePatchStore) async {
        await store.serverCheckTask?.value
    }

    /// The live case: revision 2 landed over revision 1 while the server
    /// kept running the binary it started from.
    func testAnUpdateTheServerHasNotPickedUpAsksForAHerdrRestart() async throws {
        try installOlderRevision()
        let server = ServerStub(.other)
        let store = makeStore(server: server)
        await settle(store)
        XCTAssertFalse(store.needsServerRestart, "revision 1 changes nothing on the server")

        store.requestInstall(source: .banner)
        store.confirmPendingAction()
        await store.installTask?.value
        await settle(store)

        XCTAssertEqual(store.restartReason, .updated)
        XCTAssertEqual(store.restartPrompt, .updated)
        XCTAssertTrue(store.needsServerRestart)
        XCTAssertEqual(server.asked.last, "/tmp/acme/herdr.sock")
    }

    func testAServerAlreadyOnThePatchedBinaryNeedsOnlyAFlockRestart() async throws {
        try installOlderRevision()
        let store = makeStore(server: ServerStub(.onDisk))
        store.requestInstall(source: .banner)
        store.confirmPendingAction()
        await store.installTask?.value
        await settle(store)

        XCTAssertEqual(store.restartPrompt, .updated)
        XCTAssertFalse(store.needsServerRestart)
    }

    /// No change this launch, but the server predates the patched binary:
    /// what Flock found after a plain Flock restart.
    func testAtLaunchAServerBehindThePatchedBinaryRaisesTheBanner() async throws {
        try installCurrentRevision()
        let server = ServerStub(.other)
        let store = makeStore(server: server)
        await settle(store)

        XCTAssertNil(store.restartReason)
        XCTAssertEqual(store.restartPrompt, .serverBehind)

        server.set(.onDisk)
        store.checkServer()
        await settle(store)
        XCTAssertNil(store.restartPrompt)
    }

    func testAServerThatCannotBeReadOrIsNotThisMacsIsNeverPressed() async throws {
        try installCurrentRevision()
        let unreadable = makeStore(server: ServerStub(.unknown))
        await settle(unreadable)
        XCTAssertNil(unreadable.restartPrompt)

        let server = ServerStub(.other)
        let remote = makeStore(server: server, socket: nil)
        await settle(remote)
        XCTAssertNil(remote.restartPrompt)
        XCTAssertTrue(server.asked.isEmpty)

        let clientOnly = makeStore(server: ServerStub(.other), changesServer: false)
        await settle(clientOnly)
        XCTAssertNil(clientOnly.restartPrompt)
    }

    func testRestartingHandsTheServerOffToTheBinaryOnDiskThenRelaunches() async throws {
        try installCurrentRevision()
        let runner = StubRunner()
        var relaunches = 0
        let store = makeStore(server: ServerStub(.other), runner: runner, relaunched: { relaunches += 1 })
        await settle(store)

        store.requestServerRestart(source: .banner)
        XCTAssertEqual(store.pendingConfirmation?.action, .restartServer)
        XCTAssertEqual(store.pendingConfirmation?.confirmation, HerdrMousePatchCopy.serverRestartConfirmation)
        XCTAssertEqual(relaunches, 0, "nothing runs before the confirmation")
        store.confirmPendingAction()
        XCTAssertTrue(store.serverRestarting)
        await store.serverRestartTask?.value

        XCTAssertEqual(
            runner.calls,
            [[binaryPath, "server", "live-handoff", "--import-exe", binaryPath, "--expected-version", "0.9.5"]]
        )
        XCTAssertEqual(relaunches, 1)
        XCTAssertNil(store.serverRestartError)
    }

    func testARefusedHandoffKeepsFlockRunningAndSaysHowToFinishByHand() async throws {
        try installCurrentRevision()
        let runner = StubRunner(
            status: 1, output: #"{"error":{"code":"handoff_failed","message":"handoff replacement server did not become ready"}}"#
        )
        let store = makeStore(server: ServerStub(.other), runner: runner)
        await settle(store)

        store.requestServerRestart(source: .settings)
        store.confirmPendingAction()
        await store.serverRestartTask?.value

        XCTAssertFalse(store.serverRestarting)
        XCTAssertEqual(
            store.serverRestartError,
            "herdr's server didn't restart: handoff replacement server did not become ready. To finish by hand, run "
                + "herdr server stop in a terminal, then reopen Flock. That ends every pane's shell and agent."
        )
        XCTAssertTrue(store.needsServerRestart)
    }

    func testNoRestartIsOfferedWhileNoneIsNeeded() async throws {
        try installCurrentRevision()
        let store = makeStore(server: ServerStub(.onDisk))
        await settle(store)

        store.requestServerRestart(source: .banner)
        XCTAssertNil(store.pendingConfirmation)
    }
}
