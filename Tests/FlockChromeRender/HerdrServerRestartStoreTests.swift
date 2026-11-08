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

    nonisolated(unsafe) private var defaults: UserDefaults!
    nonisolated(unsafe) private var suite: String!

    override func setUpWithError() throws {
        suite = "flock-server-restart-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        root = FileManager.default.temporaryDirectory.appendingPathComponent("flock-server-restart-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        binaryPath = root.appendingPathComponent("herdr").path
        try Data("herdr 0.9.5 unpatched build".utf8).write(to: URL(fileURLWithPath: binaryPath))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
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
        runner: StubRunner = StubRunner(), relaunched: (() -> Void)? = nil, defaults: UserDefaults? = nil
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
            defaults: defaults ?? self.defaults,
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

    /// Not now is remembered against the patch release on disk and silences
    /// only the banner: the herdr row keeps the state and its button.
    func testNotNowSilencesTheServerBannerForThisReleaseOnly() async throws {
        try installCurrentRevision()
        let store = makeStore(server: ServerStub(.other))
        await settle(store)
        XCTAssertEqual(store.bannerRestartPrompt, .serverBehind)

        store.dismissServerBehindBanner()

        XCTAssertNil(store.bannerRestartPrompt)
        XCTAssertEqual(store.restartPrompt, .serverBehind)
        XCTAssertEqual(defaults.string(forKey: "flock.herdrMousePatch.serverBehindDismissedForRelease"), "0.9.5-r2")

        let relaunched = makeStore(server: ServerStub(.other))
        await settle(relaunched)
        XCTAssertNil(relaunched.bannerRestartPrompt, "the dismissal outlives the launch")

        defaults.set("0.9.5-r1", forKey: "flock.herdrMousePatch.serverBehindDismissedForRelease")
        let older = makeStore(server: ServerStub(.other))
        await settle(older)
        XCTAssertEqual(older.bannerRestartPrompt, .serverBehind, "a dismissal for another release does not carry over")
    }

    /// A change flock just made is never silenced by an earlier Not now.
    func testNotNowDoesNotHideThePromptAfterAnUpdate() async throws {
        defaults.set("0.9.5-r2", forKey: "flock.herdrMousePatch.serverBehindDismissedForRelease")
        try installOlderRevision()
        let store = makeStore(server: ServerStub(.other))
        store.requestInstall(source: .banner)
        store.confirmPendingAction()
        await store.installTask?.value
        await settle(store)

        XCTAssertEqual(store.bannerRestartPrompt, .updated)
    }

    private func failRestart(_ store: HerdrMousePatchStore) async {
        store.requestServerRestart(source: .settings)
        store.confirmPendingAction()
        await store.serverRestartTask?.value
        await settle(store)
    }

    private var refusingRunner: StubRunner {
        StubRunner(status: 1, output: #"{"error":{"code":"handoff_failed","message":"refused"}}"#)
    }

    /// Finished by hand: the next probe finds the server on the binary on
    /// disk, which settles the failure. An unreadable server does not.
    func testAFailedRestartClearsOnceTheServerIsSeenOnTheBinaryOnDisk() async throws {
        try installCurrentRevision()
        let server = ServerStub(.other)
        let store = makeStore(server: server, runner: refusingRunner)
        await settle(store)
        await failRestart(store)
        XCTAssertNotNil(store.serverRestartError)

        server.set(.unknown)
        store.checkServer()
        await settle(store)
        XCTAssertNotNil(store.serverRestartError, "an unreadable server says nothing about the failure")

        server.set(.onDisk)
        store.checkServer()
        await settle(store)
        XCTAssertNil(store.serverRestartError)
        XCTAssertNil(store.restartPrompt)
    }

    /// Restore Original makes the restart moot, so the banner shows the
    /// restore rather than the old failure.
    func testRestoringTheOriginalClearsAFailedRestart() async throws {
        try installCurrentRevision()
        let store = makeStore(server: ServerStub(.other), runner: refusingRunner)
        await settle(store)
        await failRestart(store)
        XCTAssertNotNil(store.serverRestartError)

        store.requestRevert(source: .settings)
        store.confirmPendingAction()
        await settle(store)

        XCTAssertNil(store.serverRestartError)
        XCTAssertEqual(store.bannerRestartPrompt, .restored)
        XCTAssertFalse(store.needsServerRestart)
    }

    func testNoRestartIsOfferedWhileNoneIsNeeded() async throws {
        try installCurrentRevision()
        let store = makeStore(server: ServerStub(.onDisk))
        await settle(store)

        store.requestServerRestart(source: .banner)
        XCTAssertNil(store.pendingConfirmation)
    }
}
