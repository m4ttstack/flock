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

    private final class StubRunner: HerdrCommandRunner, @unchecked Sendable {
        var calls: [[String]] = []
        let result: (status: Int32, output: String)
        let effect: () -> Void
        init(status: Int32 = 0, output: String = "installed v0.9.5\n", effect: @escaping () -> Void = {}) {
            result = (status, output)
            self.effect = effect
        }
        func run(_ executable: String, _ arguments: [String]) async -> (status: Int32, output: String) {
            calls.append([executable] + arguments)
            effect()
            return result
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
        runner: StubRunner, transport: HerdrPatchTransport
    ) async -> (update: HerdrUpdateStore, patch: HerdrMousePatchStore) {
        let shas = ["0.9.4": sha(oldPatched), "0.9.5": sha(newPatched)]
        let patch = HerdrMousePatchStore(
            resolveBinaryPath: { [binaryPath] in binaryPath },
            catalog: { version in shas[version].map { HerdrMousePatchEntry(version: version, sha256: $0) } },
            downloader: HerdrMousePatchDownloader(cacheDirectory: root.appendingPathComponent("cache"), transport: transport)
        )
        let update = HerdrUpdateStore(
            patchStore: patch, installedVersion: { "0.9.4" }, fetchLatest: { "0.9.5" }, runner: runner
        )
        await update.checkIfDue()
        return (update, patch)
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
        let runner = StubRunner { [newStock, binaryPath] in try? newStock.write(to: URL(fileURLWithPath: binaryPath!)) }
        let transport = CountingTransport(body: newPatched)
        let (update, patch) = await makeStores(runner: runner, transport: transport)
        XCTAssertEqual(patch.state, .installed(backupPath: backupPath))

        await confirmAndWait(update)

        XCTAssertEqual(runner.calls, [[binaryPath, "update", "--handoff"]])
        XCTAssertEqual(contents(binaryPath), newPatched)
        XCTAssertEqual(contents(backupPath), newStock)
        XCTAssertEqual(patch.restartReason, .herdrUpdated(patchReinstalled: true))
        XCTAssertEqual(patch.state, .installed(backupPath: backupPath))
        XCTAssertEqual(update.updatePhase, .idle)
        XCTAssertNil(update.updateError)
        XCTAssertNil(update.notice, "an update this launch already ran is not offered again")
    }

    /// A backup gone by the time the update finishes is no obstacle: the
    /// install makes the new stock binary the backup either way.
    func testAnUpdateThatLeftNoBackupStillReinstalls() async throws {
        try installOldPatch()
        let runner = StubRunner { [newStock, binaryPath, backupPath] in
            try? newStock.write(to: URL(fileURLWithPath: binaryPath!))
            try? FileManager.default.removeItem(atPath: backupPath)
        }
        let (update, patch) = await makeStores(runner: runner, transport: CountingTransport(body: newPatched))

        await confirmAndWait(update)

        XCTAssertEqual(contents(binaryPath), newPatched)
        XCTAssertEqual(contents(backupPath), newStock)
        XCTAssertEqual(patch.restartReason, .herdrUpdated(patchReinstalled: true))
    }

    func testAnUpdateWithoutThePatchDownloadsNothing() async throws {
        try write(oldStock, to: binaryPath)
        let runner = StubRunner { [newStock, binaryPath] in try? newStock.write(to: URL(fileURLWithPath: binaryPath!)) }
        let transport = CountingTransport(body: newPatched)
        let (update, patch) = await makeStores(runner: runner, transport: transport)

        await confirmAndWait(update)

        XCTAssertEqual(transport.downloads, 0)
        XCTAssertEqual(contents(binaryPath), newStock)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupPath))
        XCTAssertEqual(patch.restartReason, .herdrUpdated(patchReinstalled: false))
        XCTAssertEqual(patch.state, .patchable(installPath: binaryPath, version: "0.9.5"))
    }

    /// The update itself landed, so Flock still has to restart; the patch
    /// failure is reported where the row reports every other one.
    func testAFailedReinstallStillAsksForTheRestart() async throws {
        try installOldPatch()
        let runner = StubRunner { [newStock, binaryPath] in try? newStock.write(to: URL(fileURLWithPath: binaryPath!)) }
        let (update, patch) = await makeStores(runner: runner, transport: CountingTransport(body: Data("<html>".utf8)))

        await confirmAndWait(update)

        XCTAssertEqual(contents(binaryPath), newStock)
        XCTAssertEqual(patch.restartReason, .herdrUpdated(patchReinstalled: false))
        XCTAssertEqual(patch.lastErrorMessage, "The download didn't match what flock expected. Nothing was changed.")
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
        let runner = StubRunner { [newStock, binaryPath] in try? newStock.write(to: URL(fileURLWithPath: binaryPath!)) }
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
