import FlockCore
import Foundation
import XCTest

/// Every path is a throwaway temp file standing in for herdr; nothing here
/// runs a binary or touches the owner's real install.
@MainActor
final class HerdrMousePatchStoreTests: XCTestCase {
    private var root: URL!
    private var binaryPath: String!
    private var artifactPath: String!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("flock-herdr-mouse-patch-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        binaryPath = root.appendingPathComponent("herdr").path
        artifactPath = root.appendingPathComponent("herdr-patched").path
        try Data("herdr 0.9.1 unpatched build".utf8).write(to: URL(fileURLWithPath: binaryPath))
        try Data("herdr 0.9.1 terminal.mouse patched build".utf8).write(to: URL(fileURLWithPath: artifactPath))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeStore(artifactAvailable: Bool = true) -> HerdrMousePatchStore {
        HerdrMousePatchStore(
            resolveBinaryPath: { [binaryPath] in binaryPath },
            resolveArtifactPath: { [artifactPath] in artifactAvailable ? artifactPath : nil }
        )
    }

    func testNoHerdrResolvesToNoState() {
        let store = HerdrMousePatchStore(resolveBinaryPath: { nil }, resolveArtifactPath: { nil })
        XCTAssertNil(store.state)
    }

    func testAPlainUnpatchedHerdrWithAnArtifactIsPatchable() {
        let store = makeStore()
        XCTAssertEqual(store.state, .patchable(installPath: binaryPath))
    }

    func testNoArtifactReadsAsArtifactUnavailable() {
        let store = makeStore(artifactAvailable: false)
        XCTAssertEqual(store.state, .artifactUnavailable(installPath: binaryPath))
    }

    func testRequestInstallOnAnUnpatchableStateDoesNothing() {
        let store = makeStore(artifactAvailable: false)
        store.requestInstall()
        XCTAssertNil(store.pendingConfirmation)
    }

    /// The confirmation must name this exact binary path, and only actually
    /// installs once `confirmPendingAction` runs.
    func testInstallGatesBehindConfirmationNamingTheExactPath() {
        let store = makeStore()

        store.requestInstall()
        XCTAssertEqual(store.pendingConfirmation?.action, .install)
        XCTAssertTrue(store.pendingConfirmation?.confirmation.message.contains(binaryPath) ?? false)
        XCTAssertEqual(try? String(contentsOfFile: binaryPath, encoding: .utf8), "herdr 0.9.1 unpatched build")

        store.confirmPendingAction()

        XCTAssertNil(store.pendingConfirmation)
        XCTAssertEqual(store.state, .installed(backupPath: HerdrMousePatchInstaller.backupPath(for: binaryPath)))
        XCTAssertEqual(
            try? String(contentsOfFile: binaryPath, encoding: .utf8), "herdr 0.9.1 terminal.mouse patched build")
    }

    func testCancelPendingConfirmationLeavesTheBinaryUntouched() {
        let store = makeStore()
        store.requestInstall()

        store.cancelPendingConfirmation()

        XCTAssertNil(store.pendingConfirmation)
        XCTAssertEqual(try? String(contentsOfFile: binaryPath, encoding: .utf8), "herdr 0.9.1 unpatched build")
    }

    func testRevertGoesBackToPatchableAndClearsTheBackup() {
        let store = makeStore()
        store.requestInstall()
        store.confirmPendingAction()
        XCTAssertEqual(store.state, .installed(backupPath: HerdrMousePatchInstaller.backupPath(for: binaryPath)))

        store.requestRevert()
        XCTAssertEqual(store.pendingConfirmation?.action, .revert)
        store.confirmPendingAction()

        XCTAssertEqual(store.state, .patchable(installPath: binaryPath))
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
    func testAFailedRevertReportsAnError() throws {
        let store = makeStore()
        store.requestInstall()
        store.confirmPendingAction()

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path) }

        store.requestRevert()
        store.confirmPendingAction()

        XCTAssertNotNil(store.lastErrorMessage)
        XCTAssertEqual(store.state, .installed(backupPath: HerdrMousePatchInstaller.backupPath(for: binaryPath)))
    }

    func testRefreshPicksUpAHerdrThatChangedUnderneathTheStore() throws {
        let store = makeStore()
        XCTAssertEqual(store.state, .patchable(installPath: binaryPath))

        try Data("herdr 0.9.1 terminal.mouse already upstream".utf8).write(to: URL(fileURLWithPath: binaryPath))
        store.refresh()

        XCTAssertEqual(store.state, .supportedByHerdr)
    }
}
