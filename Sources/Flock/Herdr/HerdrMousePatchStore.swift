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
    private(set) var restartReason: HerdrMousePatchCopy.RestartReason?
    private(set) var phase: Phase = .idle
    /// The herdr resolved by the last `refresh()`; nil when none is found.
    private(set) var binaryPath: String?

    enum Phase: Equatable { case idle, downloading(Double), installing }

    struct PendingConfirmation: Equatable {
        enum Action: Equatable { case install, revert }
        let action: Action
        let confirmation: HerdrMousePatchCopy.Confirmation
    }

    @ObservationIgnored var installTask: Task<Void, Never>?
    @ObservationIgnored private let resolveBinaryPath: () -> String?
    @ObservationIgnored private let catalog: (String) -> HerdrMousePatchEntry?
    @ObservationIgnored private let downloader: HerdrMousePatchDownloader
    @ObservationIgnored private let fileManager: FileManager
    @ObservationIgnored private let defaults: UserDefaults

    /// The herdr version the banner was last waved away for. Stored rather
    /// than held in memory because the whole point is that it outlives the
    /// launch it was answered on.
    private static let dismissedVersionKey = "flock.herdrMousePatch.offerDismissedForVersion"

    init(
        resolveBinaryPath: @escaping () -> String? = { ToolPath.resolve("herdr") },
        catalog: @escaping (String) -> HerdrMousePatchEntry? = HerdrMousePatchCatalog.entry(for:),
        downloader: HerdrMousePatchDownloader = .standard,
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard
    ) {
        self.resolveBinaryPath = resolveBinaryPath
        self.catalog = catalog
        self.downloader = downloader
        self.fileManager = fileManager
        self.defaults = defaults
        refresh()
    }

    /// Whether the banner belongs on screen right now. Read through the pure
    /// rule in FlockCore rather than decided here, so what gets offered stays
    /// testable without a herdr on disk.
    var shouldOfferBanner: Bool {
        HerdrMousePatchOffer.shouldOffer(
            state: state,
            dismissedForVersion: defaults.string(forKey: Self.dismissedVersionKey)
        )
    }

    /// Wave the banner away for this herdr version. The settings row is
    /// unaffected and still offers Install: this silences the unprompted
    /// offer, it does not withdraw the feature.
    func dismissBannerOffer() {
        guard case .patchable(_, let version) = state else { return }
        defaults.set(version, forKey: Self.dismissedVersionKey)
    }

    /// Re-probes the binary on disk. Called on init, and meant to be called
    /// again whenever the settings row appears, since herdr can be upgraded
    /// or reverted by hand between one look and the next.
    func refresh() {
        binaryPath = resolveBinaryPath()
        guard let binaryPath else {
            state = nil
            return
        }
        let probe = HerdrMousePatchInstaller.probe(binaryPath: binaryPath, fileManager: fileManager)
        state = HerdrMousePatchDecision.decide(
            hasVerbs: probe.hasVerbs,
            hasBackup: probe.hasBackup,
            version: probe.version.flatMap { catalog($0) == nil ? nil : $0 },
            isWritable: probe.isWritable,
            installPath: binaryPath,
            backupPath: HerdrMousePatchInstaller.backupPath(for: binaryPath)
        )
    }

    func requestInstall() {
        guard phase == .idle, case .patchable(let installPath, let version) = state else { return }
        pendingConfirmation = PendingConfirmation(
            action: .install,
            confirmation: HerdrMousePatchCopy.installConfirmation(installPath: installPath, version: version)
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
        guard case .patchable(_, let version) = state, let binaryPath = resolveBinaryPath(),
              let entry = catalog(version) else {
            refresh()
            return
        }
        phase = .downloading(0)
        installTask = Task { [downloader, fileManager] in
            defer { phase = .idle; refresh() }
            do {
                let artifact = try await downloader.fetch(entry) { fraction in
                    Task { @MainActor in if case .downloading = self.phase { self.phase = .downloading(fraction) } }
                }
                phase = .installing
                try HerdrMousePatchInstaller.install(artifactPath: artifact, binaryPath: binaryPath, fileManager: fileManager)
                restartReason = .installed
            } catch {
                lastErrorMessage = Self.message(for: error)
            }
        }
    }

    private func performRevert() {
        guard let binaryPath = resolveBinaryPath() else { return }
        do {
            try HerdrMousePatchInstaller.revert(binaryPath: binaryPath, fileManager: fileManager)
            restartReason = .restored
        } catch {
            lastErrorMessage = Self.message(for: error)
        }
        refresh()
    }

    private static func message(for error: Error) -> String {
        switch error {
        case HerdrMousePatchInstaller.InstallError.sourceUnreadable:
            return "The downloaded patch could not be read."
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
        case HerdrMousePatchDownloader.Failure.transport:
            return "Couldn't download the patch. Check your connection and try again."
        case HerdrMousePatchDownloader.Failure.checksumMismatch:
            return "The download didn't match what flock expected. Nothing was changed."
        default:
            return "Something went wrong."
        }
    }
}
