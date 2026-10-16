import CryptoKit
import FlockCore
import Foundation
import XCTest

/// Every path is a throwaway temp file standing in for herdr; nothing here
/// runs a binary, reaches the network or touches the owner's real install.
@MainActor
final class HerdrMousePatchStoreTests: XCTestCase {
    private var root: URL!
    private var binaryPath: String!

    private final class FileTransport: HerdrPatchTransport, @unchecked Sendable {
        var body: Data
        init(body: Data) { self.body = body }
        func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
            progress(0.5)
            try body.write(to: destination)
        }
    }

    private let patched = Data("herdr 0.9.1 terminal.mouse_capture patched build".utf8)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("flock-herdr-mouse-patch-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        binaryPath = root.appendingPathComponent("herdr").path
        try Data("herdr 0.9.1 unpatched build".utf8).write(to: URL(fileURLWithPath: binaryPath))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeStore(catalogued: Bool = true, body: Data? = nil) -> HerdrMousePatchStore {
        let sha = SHA256.hash(data: patched).map { String(format: "%02x", $0) }.joined()
        return HerdrMousePatchStore(
            resolveBinaryPath: { [binaryPath] in binaryPath },
            catalog: { catalogued ? HerdrMousePatchEntry(version: $0, sha256: sha) : nil },
            downloader: HerdrMousePatchDownloader(
                cacheDirectory: root.appendingPathComponent("cache"), transport: FileTransport(body: body ?? patched)
            )
        )
    }

    private func confirmAndWait(_ store: HerdrMousePatchStore) async {
        store.confirmPendingAction()
        await store.installTask?.value
    }

    func testNoHerdrResolvesToNoState() {
        let store = HerdrMousePatchStore(resolveBinaryPath: { nil })
        XCTAssertNil(store.state)
    }

    func testAPlainUnpatchedHerdrWithACataloguedVersionIsPatchable() {
        let store = makeStore()
        XCTAssertEqual(store.state, .patchable(installPath: binaryPath, version: "0.9.1"))
    }

    func testAnUncataloguedVersionIsUnsupported() {
        XCTAssertEqual(makeStore(catalogued: false).state, .unsupportedVersion)
    }

    func testRequestInstallOnAnUnpatchableStateDoesNothing() {
        let store = makeStore(catalogued: false)
        store.requestInstall()
        XCTAssertNil(store.pendingConfirmation)
    }

    /// The confirmation must name this exact binary path, and only actually
    /// installs once `confirmPendingAction` runs.
    func testInstallGatesBehindConfirmationNamingTheExactPath() async {
        let store = makeStore()

        store.requestInstall()
        XCTAssertEqual(store.pendingConfirmation?.action, .install)
        XCTAssertTrue(store.pendingConfirmation?.confirmation.message.contains(binaryPath) ?? false)
        XCTAssertEqual(try? String(contentsOfFile: binaryPath, encoding: .utf8), "herdr 0.9.1 unpatched build")

        await confirmAndWait(store)

        XCTAssertNil(store.pendingConfirmation)
        XCTAssertEqual(store.state, .installed(backupPath: HerdrMousePatchInstaller.backupPath(for: binaryPath)))
        XCTAssertEqual(
            try? String(contentsOfFile: binaryPath, encoding: .utf8), "herdr 0.9.1 terminal.mouse_capture patched build")
    }

    /// Running bridges keep the herdr they were started from, so only a
    /// swap that actually happened asks for a restart.
    func testASuccessfulInstallOrRestoreAsksForARestartAndAFailureDoesNot() async {
        let failing = makeStore(body: Data("<html>".utf8))
        failing.requestInstall()
        await confirmAndWait(failing)
        XCTAssertNil(failing.restartReason)
        XCTAssertEqual(failing.lastErrorMessage, "The download didn't match what flock expected. Nothing was changed.")
        XCTAssertEqual(try? String(contentsOfFile: binaryPath, encoding: .utf8), "herdr 0.9.1 unpatched build")

        let store = makeStore()
        XCTAssertNil(store.restartReason)
        store.requestInstall()
        await confirmAndWait(store)
        XCTAssertEqual(store.restartReason, .installed)

        store.requestRevert()
        store.confirmPendingAction()
        XCTAssertEqual(store.restartReason, .restored)
    }

    func testASecondInstallRequestWhileDownloadingIsIgnored() async {
        let store = makeStore()
        store.requestInstall()
        store.confirmPendingAction()
        XCTAssertNotEqual(store.phase, .idle)
        store.requestInstall()
        XCTAssertNil(store.pendingConfirmation)
        await store.installTask?.value
        XCTAssertEqual(store.phase, .idle)
    }

    private struct UpdatingTransport: HerdrPatchTransport {
        let body: Data
        let binaryPath: String
        let newer: Data
        func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
            try newer.write(to: URL(fileURLWithPath: binaryPath))
            try body.write(to: destination)
        }
    }

    /// `herdr update` run during the download replaces the binary the patch
    /// was fetched for; the older patch must not land over the newer herdr.
    func testAHerdrUpdatedMidDownloadIsLeftAlone() async throws {
        let newer = Data("herdr 0.9.6 unpatched build".utf8)
        let sha = SHA256.hash(data: patched).map { String(format: "%02x", $0) }.joined()
        let store = HerdrMousePatchStore(
            resolveBinaryPath: { [binaryPath] in binaryPath },
            catalog: { HerdrMousePatchEntry(version: $0, sha256: sha) },
            downloader: HerdrMousePatchDownloader(
                cacheDirectory: root.appendingPathComponent("cache"),
                transport: UpdatingTransport(body: patched, binaryPath: binaryPath, newer: newer)
            )
        )
        store.requestInstall()
        await confirmAndWait(store)

        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: binaryPath)), newer)
        XCTAssertFalse(FileManager.default.fileExists(atPath: HerdrMousePatchInstaller.backupPath(for: binaryPath)))
        XCTAssertEqual(store.lastErrorMessage, "herdr changed while the patch downloaded. Nothing was changed.")
        XCTAssertNil(store.restartReason)
        XCTAssertEqual(store.phase, .idle)
    }

    func testCancelPendingConfirmationLeavesTheBinaryUntouched() {
        let store = makeStore()
        store.requestInstall()

        store.cancelPendingConfirmation()

        XCTAssertNil(store.pendingConfirmation)
        XCTAssertEqual(try? String(contentsOfFile: binaryPath, encoding: .utf8), "herdr 0.9.1 unpatched build")
    }

    func testRevertGoesBackToPatchableAndClearsTheBackup() async {
        let store = makeStore()
        store.requestInstall()
        await confirmAndWait(store)
        XCTAssertEqual(store.state, .installed(backupPath: HerdrMousePatchInstaller.backupPath(for: binaryPath)))

        store.requestRevert()
        XCTAssertEqual(store.pendingConfirmation?.action, .revert)
        store.confirmPendingAction()

        XCTAssertEqual(store.state, .patchable(installPath: binaryPath, version: "0.9.1"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: HerdrMousePatchInstaller.backupPath(for: binaryPath)))
    }

    func testRequestRevertOnAPatchableStateDoesNothing() {
        let store = makeStore()
        store.requestRevert()
        XCTAssertNil(store.pendingConfirmation)
    }

    /// A revert that fails partway (destination directory not writable)
    /// surfaces a message rather than silently doing nothing; the row reads
    /// it back from `lastErrorMessage`.
    func testAFailedRevertReportsAnError() async throws {
        let store = makeStore()
        store.requestInstall()
        await confirmAndWait(store)

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path) }

        store.requestRevert()
        store.confirmPendingAction()

        XCTAssertNotNil(store.lastErrorMessage)
        XCTAssertEqual(store.state, .installed(backupPath: HerdrMousePatchInstaller.backupPath(for: binaryPath)))
    }

    func testRefreshPicksUpAHerdrThatChangedUnderneathTheStore() throws {
        let store = makeStore()
        XCTAssertEqual(store.state, .patchable(installPath: binaryPath, version: "0.9.1"))

        try Data("herdr 0.9.1 terminal.mouse_capture already upstream".utf8).write(to: URL(fileURLWithPath: binaryPath))
        store.refresh()

        XCTAssertEqual(store.state, .supportedByHerdr)
    }
}
