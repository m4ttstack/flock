import FlockCore
import Foundation
import Observation

/// Drives the herdr settings row: resolves the installed herdr the same way
/// `HerdrToolStore` does, probes its bytes, and maps the probe through
/// FlockCore's pure decision matrix. Re-derives everything from disk on
/// every `refresh()` rather than caching across a herdr upgrade, since a
/// binary replaced out from under a stale answer is the ordinary case this
/// exists to notice.
@MainActor
@Observable
final class HerdrMousePatchStore {
    private(set) var state: HerdrMousePatchRowState?
    private(set) var pendingConfirmation: PendingConfirmation?
    private(set) var lastErrorMessage: String?

    struct PendingConfirmation: Equatable {
        enum Action: Equatable { case install, revert }
        let action: Action
        let confirmation: HerdrMousePatchCopy.Confirmation
    }

    @ObservationIgnored private let resolveBinaryPath: () -> String?
    @ObservationIgnored private let resolveArtifactPath: () -> String?
    @ObservationIgnored private let fileManager: FileManager

    init(
        resolveBinaryPath: @escaping () -> String? = { ToolPath.resolve("herdr") },
        resolveArtifactPath: @escaping () -> String? = { HerdrMousePatchArtifactLocator.path() },
        fileManager: FileManager = .default
    ) {
        self.resolveBinaryPath = resolveBinaryPath
        self.resolveArtifactPath = resolveArtifactPath
        self.fileManager = fileManager
        refresh()
    }

    /// Re-probes the binary on disk. Called on init, and meant to be called
    /// again whenever the settings row appears, since herdr can be upgraded
    /// or reverted by hand between one look and the next.
    func refresh() {
        guard let binaryPath = resolveBinaryPath() else {
            state = nil
            return
        }
        let probe = HerdrMousePatchInstaller.probe(binaryPath: binaryPath, fileManager: fileManager)
        state = HerdrMousePatchDecision.decide(
            hasVerbs: probe.hasVerbs,
            hasBackup: probe.hasBackup,
            versionSupported: probe.versionSupported,
            isWritable: probe.isWritable,
            artifactAvailable: resolveArtifactPath() != nil,
            installPath: binaryPath,
            backupPath: HerdrMousePatchInstaller.backupPath(for: binaryPath)
        )
    }

    func requestInstall() {
        guard case .patchable(let installPath) = state else { return }
        pendingConfirmation = PendingConfirmation(
            action: .install, confirmation: HerdrMousePatchCopy.installConfirmation(installPath: installPath)
        )
    }

    func requestRevert() {
        guard case .installed = state, let binaryPath = resolveBinaryPath() else { return }
        pendingConfirmation = PendingConfirmation(
            action: .revert, confirmation: HerdrMousePatchCopy.revertConfirmation(installPath: binaryPath)
        )
    }

    func cancelPendingConfirmation() {
        pendingConfirmation = nil
    }

    func confirmPendingAction() {
        guard let pending = pendingConfirmation else { return }
        pendingConfirmation = nil
        lastErrorMessage = nil
        switch pending.action {
        case .install: performInstall()
        case .revert: performRevert()
        }
    }

    private func performInstall() {
        guard let binaryPath = resolveBinaryPath(), let artifactPath = resolveArtifactPath() else {
            refresh()
            return
        }
        do {
            try HerdrMousePatchInstaller.install(artifactPath: artifactPath, binaryPath: binaryPath, fileManager: fileManager)
        } catch {
            lastErrorMessage = Self.message(for: error)
        }
        refresh()
    }

    private func performRevert() {
        guard let binaryPath = resolveBinaryPath() else { return }
        do {
            try HerdrMousePatchInstaller.revert(binaryPath: binaryPath, fileManager: fileManager)
        } catch {
            lastErrorMessage = Self.message(for: error)
        }
        refresh()
    }

    private static func message(for error: Error) -> String {
        switch error {
        case HerdrMousePatchInstaller.InstallError.sourceUnreadable:
            return "The bundled patch could not be read."
        case HerdrMousePatchInstaller.InstallError.backupAlreadyExists:
            return "A backup already sits beside herdr; revert before installing again."
        case HerdrMousePatchInstaller.InstallError.destinationNotWritable,
            HerdrMousePatchInstaller.RevertError.destinationNotWritable:
            return "herdr's install location is not writable."
        case HerdrMousePatchInstaller.InstallError.renameFailed,
            HerdrMousePatchInstaller.RevertError.renameFailed:
            return "The file move failed partway through."
        case HerdrMousePatchInstaller.InstallError.verificationFailed:
            return "The installed binary did not verify; the original was restored."
        case HerdrMousePatchInstaller.RevertError.verificationFailed:
            return "The reverted binary still carries the mouse verbs."
        case HerdrMousePatchInstaller.RevertError.backupMissing:
            return "No backup is available to revert to."
        default:
            return "Something went wrong."
        }
    }
}
