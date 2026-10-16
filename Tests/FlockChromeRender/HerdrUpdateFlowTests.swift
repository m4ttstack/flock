import CryptoKit
import FlockCore
import Foundation
import XCTest

/// The update run end to end against a temp file standing in for herdr: a
/// stub runner plays `herdr update --handoff` by rewriting that file, and a
/// stub transport serves the patch. Nothing runs a binary or reaches the
/// network.
@MainActor
final class HerdrUpdateFlowTests: XCTestCase {
    nonisolated(unsafe) private var root: URL!
    nonisolated(unsafe) private var binaryPath: String!
    private var backupPath: String { HerdrMousePatchInstaller.backupPath(for: binaryPath) }

    private let oldStock = Data("herdr 0.9.4 unpatched build".utf8)
    private let oldPatched = Data("herdr 0.9.4 terminal.mouse_capture patched build".utf8)
    private let newStock = Data("herdr 0.9.5 unpatched build".utf8)
    private let newPatched = Data("herdr 0.9.5 terminal.mouse_capture patched build".utf8)

    /// Answers each run with the next scripted reply, the last one repeating.
    private final class StubRunner: HerdrCommandRunner, @unchecked Sendable {
        struct Reply {
            var status: Int32 = 0
            var output = "installed 0.9.5\n"
            var effect: () -> Void = {}
        }
        var calls: [[String]] = []
        private var replies: [Reply]
        init(_ replies: [Reply]) { self.replies = replies }
        convenience init(status: Int32 = 0, output: String = "installed 0.9.5\n", effect: @escaping () -> Void = {}) {
            self.init([Reply(status: status, output: output, effect: effect)])
        }
        func run(_ executable: String, _ arguments: [String]) async -> (status: Int32, output: String) {
            calls.append([executable] + arguments)
            let reply = replies.count > 1 ? replies.removeFirst() : replies[0]
            reply.effect()
            return (reply.status, reply.output)
        }
    }

    /// Holds the reinstall's download until the test lets it go.
    private final class GatedTransport: HerdrPatchTransport, @unchecked Sendable {
        let body: Data
        private let lock = NSLock()
        private var started = false
        private var released = false
        init(body: Data) { self.body = body }
        var hasStarted: Bool { lock.withLock { started } }
        func release() { lock.withLock { released = true } }
        func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
            lock.withLock { started = true }
            while !lock.withLock({ released }) { try await Task.sleep(for: .milliseconds(5)) }
            try body.write(to: destination)
        }
    }

    private final class CountingTransport: HerdrPatchTransport, @unchecked Sendable {
        var downloads = 0
        let body: Data
        init(body: Data) { self.body = body }
        func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
            downloads += 1
            try body.write(to: destination)
        }
    }

    private struct HangingTransport: HerdrPatchTransport {
        func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
            progress(0.4)
            try await Task.sleep(for: .seconds(3600))
        }
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("flock-herdr-update-flow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        binaryPath = root.appendingPathComponent("herdr").path
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func write(_ data: Data, to path: String) throws {
        try data.write(to: URL(fileURLWithPath: path))
    }

    private func contents(_ path: String) -> Data? {
        FileManager.default.contents(atPath: path)
    }

    private func makeStores(
        runner: StubRunner, transport: HerdrPatchTransport, running: String = "0.9.4"
    ) async -> (update: HerdrUpdateStore, patch: HerdrMousePatchStore) {
        let shas = ["0.9.4": sha(oldPatched), "0.9.5": sha(newPatched)]
        let patch = HerdrMousePatchStore(
            resolveBinaryPath: { [binaryPath] in binaryPath },
            catalog: { version in shas[version].map { HerdrMousePatchEntry(version: version, sha256: $0) } },
            downloader: HerdrMousePatchDownloader(cacheDirectory: root.appendingPathComponent("cache"), transport: transport)
        )
        let update = HerdrUpdateStore(
            patchStore: patch, installedVersion: { running }, fetchLatest: { "0.9.5" }, runner: runner
        )
        await update.checkIfDue()
        return (update, patch)
    }

    /// What herdr's install does: a new file renamed over the old one.
    private func installing(_ data: Data) -> () -> Void {
        { [binaryPath] in try? data.write(to: URL(fileURLWithPath: binaryPath!), options: .atomic) }
    }

    private func installOldPatch() throws {
        try write(oldPatched, to: binaryPath)
        try write(oldStock, to: backupPath)
    }

    private func confirmAndWait(_ update: HerdrUpdateStore) async {
        update.requestUpdate()
        XCTAssertEqual(update.pendingUpdate?.title, "Update herdr to 0.9.5?")
        update.confirmUpdate()
        XCTAssertEqual(update.updatePhase, .updating)
        await update.updateTask?.value
    }

    /// herdr's own update leaves the old stock binary as the backup; it
    /// belongs to the version just replaced, so the new stock binary takes
    /// its place under the reinstalled patch.
    func testAnUpdateWithThePatchInstalledReinstallsItOverTheNewHerdr() async throws {
        try installOldPatch()
        let runner = StubRunner(effect: installing(newStock))
        let transport = CountingTransport(body: newPatched)
        let (update, patch) = await makeStores(runner: runner, transport: transport)
        XCTAssertEqual(patch.state, .installed(backupPath: backupPath))

        await confirmAndWait(update)

        XCTAssertEqual(runner.calls, [[binaryPath, "update", "--handoff"]])
        XCTAssertEqual(contents(binaryPath), newPatched)
        XCTAssertEqual(contents(backupPath), newStock)
        XCTAssertEqual(patch.restartReason, .herdrUpdated(.reinstalled))
        XCTAssertEqual(patch.state, .installed(backupPath: backupPath))
        XCTAssertEqual(update.updatePhase, .idle)
        XCTAssertNil(update.updateError)
        XCTAssertNil(update.notice, "an update this launch already ran is not offered again")
    }

    /// A backup gone by the time the update finishes is no obstacle: the
    /// install makes the new stock binary the backup either way.
    func testAnUpdateThatLeftNoBackupStillReinstalls() async throws {
        try installOldPatch()
        let install = installing(newStock)
        let runner = StubRunner { [backupPath] in
            install()
            try? FileManager.default.removeItem(atPath: backupPath)
        }
        let (update, patch) = await makeStores(runner: runner, transport: CountingTransport(body: newPatched))

        await confirmAndWait(update)

        XCTAssertEqual(contents(binaryPath), newPatched)
        XCTAssertEqual(contents(backupPath), newStock)
        XCTAssertEqual(patch.restartReason, .herdrUpdated(.reinstalled))
    }

    func testAnUpdateWithoutThePatchDownloadsNothing() async throws {
        try write(oldStock, to: binaryPath)
        let runner = StubRunner(effect: installing(newStock))
        let transport = CountingTransport(body: newPatched)
        let (update, patch) = await makeStores(runner: runner, transport: transport)

        await confirmAndWait(update)

        XCTAssertEqual(transport.downloads, 0)
        XCTAssertEqual(contents(binaryPath), newStock)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupPath))
        XCTAssertEqual(patch.restartReason, .herdrUpdated(.untouched))
        XCTAssertEqual(patch.state, .patchable(installPath: binaryPath, version: "0.9.5"))
    }

    /// The update itself landed, so Flock still has to restart; the banner
    /// says the patch is off and the row says why.
    func testAFailedReinstallStillAsksForTheRestart() async throws {
        try installOldPatch()
        let runner = StubRunner(effect: installing(newStock))
        let (update, patch) = await makeStores(runner: runner, transport: CountingTransport(body: Data("<html>".utf8)))

        await confirmAndWait(update)

        XCTAssertEqual(contents(binaryPath), newStock)
        XCTAssertEqual(patch.restartReason, .herdrUpdated(.reinstallFailed))
        XCTAssertEqual(
            HerdrMousePatchCopy.restartDetail(for: try XCTUnwrap(patch.restartReason)),
            "Mouse support couldn't be reinstalled; see Settings."
        )
        XCTAssertEqual(patch.lastErrorMessage, "The download didn't match what flock expected. Nothing was changed.")
    }

    /// Every pane lost its server in the handoff; the banner says so while
    /// the patch is still downloading, and the Settings progress stays up
    /// though the finished update has taken the notice away.
    func testTheRestartBannerGoesUpBeforeTheReinstallFinishes() async throws {
        try installOldPatch()
        let runner = StubRunner(effect: installing(newStock))
        let transport = GatedTransport(body: newPatched)
        let (update, patch) = await makeStores(runner: runner, transport: transport)
        let notice = try XCTUnwrap(update.notice)

        update.requestUpdate()
        update.confirmUpdate()
        let deadline = Date().addingTimeInterval(10)
        while !transport.hasStarted, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }

        XCTAssertTrue(transport.hasStarted)
        XCTAssertEqual(patch.restartReason, .herdrUpdated(.reinstalling))
        XCTAssertFalse(HerdrMousePatchCopy.offersRestart(for: try XCTUnwrap(patch.restartReason)))
        XCTAssertEqual(update.updatePhase, .updating)
        XCTAssertNil(update.notice)
        XCTAssertEqual(update.displayedNotice, notice)

        transport.release()
        await update.updateTask?.value

        XCTAssertEqual(patch.restartReason, .herdrUpdated(.reinstalled))
        XCTAssertNil(update.displayedNotice)
    }

    /// herdr printed its handoff line; the binary on disk counts for nothing
    /// here, since herdr's own words already say the server moved.
    func testAHandoffLineAloneIsAnUpdate() async throws {
        try write(oldStock, to: binaryPath)
        let output = "installed 0.9.5\nlive handoff complete for session default; pane processes should still be running.\n"
        let runner = StubRunner(output: output)
        let (update, patch) = await makeStores(runner: runner, transport: CountingTransport(body: newPatched))

        await confirmAndWait(update)

        XCTAssertNil(update.updateError)
        XCTAssertEqual(patch.restartReason, .herdrUpdated(.untouched))
    }

    /// The restart that followed the first "already up to date" would only
    /// reconnect to the same old server, so flock hands it off itself.
    func testAlreadyUpToDateWithAnOlderServerHandsTheServerOff() async throws {
        try write(newStock, to: binaryPath)
        let runner = StubRunner([
            .init(output: "checking stable channel for updates...\nalready up to date (0.9.5)\n"),
            .init(output: "live handoff complete; server log: /tmp/acme/herdr-server.log\n"),
        ])
        let (update, patch) = await makeStores(runner: runner, transport: CountingTransport(body: newPatched))

        await confirmAndWait(update)

        XCTAssertEqual(runner.calls, [
            [binaryPath, "update", "--handoff"],
            [binaryPath, "server", "live-handoff", "--import-exe", binaryPath, "--expected-version", "0.9.5"],
        ])
        XCTAssertNil(update.updateError)
        XCTAssertEqual(patch.restartReason, .herdrUpdated(.untouched))
        XCTAssertNil(update.notice)
    }

    func testAServerHandoffThatFailsAsksForAServerRestartInstead() async throws {
        try write(newStock, to: binaryPath)
        let runner = StubRunner([
            .init(output: "already up to date (0.9.5)\n"),
            .init(status: 1, output: #"{"error":{"code":"handoff_failed","message":"handoff import did not validate manifest"}}"#),
        ])
        let (update, patch) = await makeStores(runner: runner, transport: CountingTransport(body: newPatched))

        await confirmAndWait(update)

        XCTAssertEqual(runner.calls.count, 2)
        XCTAssertEqual(
            update.updateError,
            "herdr is already updated on disk but the running server is older. Restart herdr's server to finish."
        )
        XCTAssertNil(patch.restartReason)
        XCTAssertNotNil(update.notice)
    }

    /// herdr's manifest and flock's disagree about what is newest; the
    /// server already runs what is on disk, so there is nothing to hand off.
    func testAlreadyUpToDateWithACurrentServerIsNotAnUpdate() async throws {
        try write(oldStock, to: binaryPath)
        let runner = StubRunner(output: "already up to date (0.9.4)\n")
        let (update, patch) = await makeStores(runner: runner, transport: CountingTransport(body: newPatched))

        await confirmAndWait(update)

        XCTAssertEqual(runner.calls.count, 1)
        XCTAssertEqual(update.updateError, "herdr didn't hand off to the new version. Nothing else was changed.")
        XCTAssertNil(patch.restartReason)
    }

    func testACleanExitWithNoHandoffAndNoNewBinaryChangesNothing() async throws {
        try installOldPatch()
        let output = "installed 0.9.5\nnot stopping the old server from a non-interactive update; run `herdr server stop` when you are ready.\n"
        let transport = CountingTransport(body: newPatched)
        let (update, patch) = await makeStores(runner: StubRunner(output: output), transport: transport)

        await confirmAndWait(update)

        XCTAssertEqual(update.updateError, "herdr didn't hand off to the new version. Nothing else was changed.")
        XCTAssertNil(patch.restartReason)
        XCTAssertEqual(transport.downloads, 0)
        XCTAssertEqual(contents(binaryPath), oldPatched)
        XCTAssertNotNil(update.notice)
    }

    func testAFailedUpdateShowsHerdrsLastLineAndChangesNothing() async throws {
        try installOldPatch()
        let runner = StubRunner(status: 1, output: "checking stable channel for updates...\nupdate failed: download failed\n")
        let transport = CountingTransport(body: newPatched)
        let (update, patch) = await makeStores(runner: runner, transport: transport)

        await confirmAndWait(update)

        XCTAssertEqual(update.updateError, "herdr couldn't update: download failed")
        XCTAssertEqual(update.updatePhase, .idle)
        XCTAssertEqual(contents(binaryPath), oldPatched)
        XCTAssertEqual(contents(backupPath), oldStock)
        XCTAssertNil(patch.restartReason)
        XCTAssertEqual(transport.downloads, 0)
        XCTAssertNotNil(update.notice, "the update is still on offer after a failure")
    }

    func testAHomebrewHerdrIsNeverRunByFlock() async throws {
        let cellar = root.appendingPathComponent("Cellar/herdr/0.9.4/bin")
        try FileManager.default.createDirectory(at: cellar, withIntermediateDirectories: true)
        binaryPath = cellar.appendingPathComponent("herdr").path
        try write(oldStock, to: binaryPath)
        let runner = StubRunner()
        let (update, _) = await makeStores(runner: runner, transport: CountingTransport(body: newPatched))
        XCTAssertEqual(update.notice?.command, "brew upgrade herdr")

        update.requestUpdate()

        XCTAssertNil(update.pendingUpdate)
        XCTAssertFalse(update.canRunUpdate)
        update.confirmUpdate()
        XCTAssertNil(update.updateTask)
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testASecondRequestWhileUpdatingIsIgnored() async throws {
        try write(oldStock, to: binaryPath)
        let runner = StubRunner()
        let (update, _) = await makeStores(runner: runner, transport: CountingTransport(body: newPatched))

        update.requestUpdate()
        update.confirmUpdate()
        update.requestUpdate()
        XCTAssertNil(update.pendingUpdate)
        await update.updateTask?.value

        XCTAssertEqual(runner.calls.count, 1)
    }

    /// Replacing herdr under a patch install would leave the install
    /// verifying against a binary it never saw.
    func testAnUpdateIsRefusedWhileAPatchInstallRuns() async throws {
        try write(oldStock, to: binaryPath)
        let runner = StubRunner()
        let (update, patch) = await makeStores(runner: runner, transport: HangingTransport())
        patch.requestInstall(source: .settings)
        patch.confirmPendingAction()
        XCTAssertNotEqual(patch.phase, .idle)

        XCTAssertTrue(update.isBlockedByPatchInstall)
        update.requestUpdate()
        XCTAssertNil(update.pendingUpdate)
        update.confirmUpdate()
        XCTAssertNil(update.updateTask)
        XCTAssertEqual(update.updatePhase, .idle)

        patch.installTask?.cancel()
        await patch.installTask?.value
        XCTAssertFalse(update.isBlockedByPatchInstall)
        XCTAssertTrue(runner.calls.isEmpty)
    }

    /// The banner or row cannot start an install of the herdr the update is
    /// replacing; only the update's own reinstall runs, after it.
    func testAPatchInstallIsRefusedWhileAnUpdateRuns() async throws {
        try write(oldStock, to: binaryPath)
        let runner = StubRunner(effect: installing(newStock))
        let transport = CountingTransport(body: newPatched)
        let (update, patch) = await makeStores(runner: runner, transport: transport)
        patch.requestInstall(source: .banner)
        XCTAssertNotNil(patch.pendingConfirmation)

        update.requestUpdate()
        update.confirmUpdate()

        XCTAssertTrue(patch.herdrUpdateInProgress)
        XCTAssertNil(patch.pendingConfirmation, "a confirmation asked for before the update is withdrawn")
        XCTAssertFalse(patch.shouldOfferBanner)
        patch.requestInstall(source: .banner)
        XCTAssertNil(patch.pendingConfirmation)
        patch.requestInstall(source: .settings)
        XCTAssertNil(patch.pendingConfirmation)

        await update.updateTask?.value

        XCTAssertFalse(patch.herdrUpdateInProgress)
        XCTAssertEqual(transport.downloads, 0)
        XCTAssertEqual(contents(binaryPath), newStock)
    }

    func testCancellingTheConfirmationRunsNothing() async throws {
        try write(oldStock, to: binaryPath)
        let runner = StubRunner()
        let (update, _) = await makeStores(runner: runner, transport: CountingTransport(body: newPatched))

        update.requestUpdate()
        update.cancelUpdate()
        update.confirmUpdate()

        XCTAssertNil(update.pendingUpdate)
        XCTAssertNil(update.updateTask)
        XCTAssertEqual(update.updatePhase, .idle)
        XCTAssertTrue(runner.calls.isEmpty)
    }
}
