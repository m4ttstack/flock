import FlockCore
import Foundation
import Observation

/// Drives the herdr settings row: resolves the installed herdr the same way
/// `HerdrToolStore` does, probes its bytes and `--version`, and maps the probe through
/// FlockCore's pure decision matrix. A binary replaced out from under a
/// stale answer is the ordinary case this exists to notice, so `refresh()`
/// re-probes whenever the file's identity on disk has moved.
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
    /// Set by `HerdrUpdateStore` around `herdr update`. A patch installed
    /// while the binary is being replaced would land on the wrong version,
    /// so Install and Restore are withdrawn until it ends; only the update's
    /// own `reinstallAfterUpdate` runs meanwhile.
    private(set) var herdrUpdateInProgress = false
    /// Which binary the connected server runs, read by `checkServer()`.
    private(set) var serverBinary: HerdrServerBinary = .unknown
    /// The version the last probe read from the binary on disk.
    private(set) var binaryVersion: String?
    /// A live handoff is running; Flock relaunches when it lands.
    private(set) var serverRestarting = false
    private(set) var serverRestartError: String?
    /// The patch release the at-launch server banner was waved away for.
    private(set) var serverBehindDismissedFor: String?

    enum Phase: Equatable { case idle, downloading(Double), installing }

    /// The banner and the Settings row both watch this store, and each
    /// presents only the confirmations it asked for.
    struct PendingConfirmation: Equatable {
        enum Action: Equatable { case install, revert, restartServer }
        enum Source: Equatable { case banner, settings }
        let action: Action
        let confirmation: HerdrMousePatchCopy.Confirmation
        let source: Source
    }

    @ObservationIgnored var installTask: Task<Void, Never>?
    @ObservationIgnored var serverCheckTask: Task<Void, Never>?
    @ObservationIgnored var serverRestartTask: Task<Void, Never>?
    @ObservationIgnored private let resolveBinaryPath: () -> String?
    @ObservationIgnored private let catalog: (String) -> HerdrMousePatchEntry?
    @ObservationIgnored private let downloader: HerdrMousePatchDownloader
    @ObservationIgnored private let fileManager: FileManager
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let probe: (String, FileManager) -> HerdrMousePatchInstaller.Probe
    @ObservationIgnored private var lastProbed: BinaryFingerprint?
    /// The socket of the server this Flock is on, nil when that server is not
    /// this Mac's (a machine session) and so not this herdr's to restart.
    @ObservationIgnored private let serverSocketPath: () -> String?
    @ObservationIgnored private let probeServer: @Sendable (String, String) -> HerdrServerBinary
    @ObservationIgnored private let runner: HerdrCommandRunner
    @ObservationIgnored private let relaunch: () -> Void

    /// The probe reads all of herdr (over 20 MB) and runs it on the main
    /// actor, and the app calls `refresh()` on every activation; these stat fields change
    /// whenever anything the probe reports could have.
    struct BinaryFingerprint: Equatable {
        let binary: FileIdentity
        let backupModified: Date?
        let backupExists: Bool
        let isWritable: Bool
    }

    /// herdr installs an update by renaming a new file over the old one,
    /// which always changes the inode; size and mtime catch a rewrite in place.
    struct FileIdentity: Equatable {
        let resolvedPath: String
        let inode: Int?
        let size: Int?
        let modified: Date?
    }

    /// The herdr version the banner was last waved away for. Stored rather
    /// than held in memory because the whole point is that it outlives the
    /// launch it was answered on.
    private static let dismissedVersionKey = "flock.herdrMousePatch.offerDismissedForVersion"
    private static let serverBehindDismissedKey = "flock.herdrMousePatch.serverBehindDismissedForRelease"

    init(
        resolveBinaryPath: @escaping () -> String? = { ToolPath.resolve("herdr") },
        catalog: @escaping (String) -> HerdrMousePatchEntry? = HerdrMousePatchCatalog.entry(for:),
        downloader: HerdrMousePatchDownloader = .standard,
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard,
        readVersionOutput: @escaping (String) -> String? = { HerdrVersionReader().read(binaryPath: $0) },
        probe: ((String, FileManager) -> HerdrMousePatchInstaller.Probe)? = nil,
        serverSocketPath: @escaping () -> String? = { nil },
        probeServer: @escaping @Sendable (String, String) -> HerdrServerBinary = HerdrServerBinary.probe(socketPath:binaryPath:),
        runner: HerdrCommandRunner = ProcessHerdrCommandRunner(),
        relaunch: @escaping () -> Void = { AppRelaunch.relaunch() }
    ) {
        self.resolveBinaryPath = resolveBinaryPath
        self.serverSocketPath = serverSocketPath
        self.probeServer = probeServer
        self.runner = runner
        self.relaunch = relaunch
        self.catalog = catalog
        self.downloader = downloader
        self.fileManager = fileManager
        self.defaults = defaults
        serverBehindDismissedFor = defaults.string(forKey: Self.serverBehindDismissedKey)
        self.probe = probe ?? {
            HerdrMousePatchInstaller.probe(binaryPath: $0, fileManager: $1, readVersionOutput: readVersionOutput)
        }
        refresh()
    }

    /// Whether the banner belongs on screen right now. Read through the pure
    /// rule in FlockCore rather than decided here, so what gets offered stays
    /// testable without a herdr on disk.
    var shouldOfferBanner: Bool {
        !herdrUpdateInProgress && HerdrMousePatchOffer.shouldOffer(
            state: state,
            dismissedForVersion: defaults.string(forKey: Self.dismissedVersionKey)
        )
    }

    /// An install begun from the banner that failed. The banner stays up to
    /// say so even when the failure left herdr no longer patchable, which
    /// would otherwise take the banner away with no word on what happened.
    private(set) var bannerErrorMessage: String?

    var showsBanner: Bool { shouldOfferBanner || bannerErrorMessage != nil }

    /// flock's current patch is on disk but the server still runs an older
    /// binary, so the patch's server half is missing until herdr restarts.
    var needsServerRestart: Bool {
        HerdrServerRestart.isNeeded(
            state: state, patchChangesServer: binaryVersion.flatMap(catalog)?.changesServer ?? false, server: serverBinary
        )
    }

    /// What the restart banner and row show: the change flock just made, or
    /// with none, a server found behind the patched binary on disk.
    var restartPrompt: HerdrMousePatchCopy.RestartReason? {
        restartReason ?? (needsServerRestart ? .serverBehind : nil)
    }

    /// The banner's prompt: the row's, less a server banner waved away for
    /// the patch release on disk. A newer release raises it again.
    var bannerRestartPrompt: HerdrMousePatchCopy.RestartReason? {
        guard let prompt = restartPrompt else { return nil }
        guard prompt == .serverBehind, let release = installedRelease else { return prompt }
        return serverBehindDismissedFor == release ? nil : prompt
    }

    private var installedRelease: String? { binaryVersion.flatMap(catalog)?.releaseName }

    func dismissServerBehindBanner() {
        guard let release = installedRelease else { return }
        defaults.set(release, forKey: Self.serverBehindDismissedKey)
        serverBehindDismissedFor = release
    }

    /// Wave the banner away for this herdr version. The settings row is
    /// unaffected and still offers Install: this silences the unprompted
    /// offer, it does not withdraw the feature.
    func dismissBannerOffer() {
        bannerErrorMessage = nil
        guard let state, let token = HerdrMousePatchOffer.dismissalToken(for: state) else { return }
        defaults.set(token, forKey: Self.dismissedVersionKey)
    }

    /// Re-probes the binary when its fingerprint moved since the last probe.
    /// Called on init, whenever the settings row appears, the app becomes
    /// active or the server's herdr version changes, since herdr can be
    /// upgraded or reverted by hand between one look and the next.
    func refresh() {
        refresh(force: false)
    }

    /// Re-probes unconditionally: after flock itself changed the binary, a
    /// write inside the stat fields' resolution must not be missed.
    func reprobe() {
        refresh(force: true)
    }

    private func refresh(force: Bool) {
        let resolved = resolveBinaryPath()
        if binaryPath != resolved { binaryPath = resolved }
        guard let resolved else {
            lastProbed = nil
            if state != nil { state = nil }
            checkServer()
            return
        }
        // The server can be restarted while the binary stays put, so this
        // runs whether or not the binary is probed again.
        defer { checkServer() }
        let fingerprint = fingerprint(of: resolved)
        if !force, fingerprint == lastProbed { return }
        let probe = probe(resolved, fileManager)
        lastProbed = fingerprint
        if binaryVersion != probe.version { binaryVersion = probe.version }
        let entry = probe.version.flatMap(catalog)
        let decided = HerdrMousePatchDecision.decide(
            hasVerbs: probe.hasVerbs,
            hasBackup: probe.hasBackup,
            version: entry == nil ? nil : probe.version,
            isWritable: probe.isWritable,
            installPath: resolved,
            backupPath: HerdrMousePatchInstaller.backupPath(for: resolved),
            newerRelease: entry.flatMap { $0.supersedes(sha256: probe.sha256) ? $0.releaseName : nil }
        )
        if state != decided { state = decided }
    }

    /// Reads which binary the connected server runs. Called on every refresh
    /// and whenever the connection changes, since either can move it.
    func checkServer() {
        serverCheckTask?.cancel()
        guard let binaryPath, let socket = serverSocketPath() else {
            if serverBinary != .unknown { serverBinary = .unknown }
            return
        }
        let probeServer = probeServer
        serverCheckTask = Task {
            let found = await Task.detached { probeServer(socket, binaryPath) }.value
            guard !Task.isCancelled else { return }
            // Only a server seen on the binary on disk settles a failed
            // restart: an unreadable one says nothing about it.
            if found == .onDisk, serverRestartError != nil { serverRestartError = nil }
            if found != serverBinary { serverBinary = found }
        }
    }

    /// Asks to hand the server off to the binary on disk.
    func requestServerRestart(source: PendingConfirmation.Source) {
        guard needsServerRestart, !serverRestarting, phase == .idle, !herdrUpdateInProgress else { return }
        pendingConfirmation = PendingConfirmation(
            action: .restartServer, confirmation: HerdrMousePatchCopy.serverRestartConfirmation, source: source
        )
    }

    /// The herdr on disk right now, for telling whether a run replaced it.
    func binaryIdentity() -> FileIdentity? {
        resolveBinaryPath().map(identity(of:))
    }

    private func identity(of binaryPath: String) -> FileIdentity {
        let resolved = URL(fileURLWithPath: binaryPath).resolvingSymlinksInPath().path
        let attributes = try? fileManager.attributesOfItem(atPath: resolved)
        return FileIdentity(
            resolvedPath: resolved,
            inode: (attributes?[.systemFileNumber] as? NSNumber)?.intValue,
            size: (attributes?[.size] as? NSNumber)?.intValue,
            modified: attributes?[.modificationDate] as? Date
        )
    }

    private func fingerprint(of binaryPath: String) -> BinaryFingerprint {
        let backup = try? fileManager.attributesOfItem(atPath: HerdrMousePatchInstaller.backupPath(for: binaryPath))
        return BinaryFingerprint(
            binary: identity(of: binaryPath),
            backupModified: backup?[.modificationDate] as? Date,
            backupExists: backup != nil,
            isWritable: fileManager.isWritableFile(atPath: URL(fileURLWithPath: binaryPath).deletingLastPathComponent().path)
        )
    }

    /// Asks to install the patch on a patchable herdr, or to put the newer
    /// revision in place of an outdated one.
    func requestInstall(source: PendingConfirmation.Source) {
        guard phase == .idle, !herdrUpdateInProgress else { return }
        let confirmation: HerdrMousePatchCopy.Confirmation
        switch state {
        case .patchable(let installPath, let version):
            confirmation = HerdrMousePatchCopy.installConfirmation(installPath: installPath, version: version)
        case .outdated(let installPath, let version, _, _):
            confirmation = HerdrMousePatchCopy.updateConfirmation(installPath: installPath, version: version)
        default:
            return
        }
        pendingConfirmation = PendingConfirmation(action: .install, confirmation: confirmation, source: source)
    }

    func requestRevert(source: PendingConfirmation.Source) {
        guard !herdrUpdateInProgress, state?.hasFlockPatch == true, let binaryPath = resolveBinaryPath() else { return }
        pendingConfirmation = PendingConfirmation(
            action: .revert, confirmation: HerdrMousePatchCopy.revertConfirmation(installPath: binaryPath), source: source
        )
    }

    /// Puts the patch back on the herdr `herdr update` just installed. The
    /// update's own confirmation promised this, so it asks nothing more.
    /// Returns whether the patch is installed afterwards.
    func reinstallAfterUpdate() async -> Bool {
        guard phase == .idle, case .patchable = state else { return false }
        lastErrorMessage = nil
        performInstall(startedFromBanner: false)
        await installTask?.value
        return state?.hasFlockPatch == true
    }

    func noteHerdrUpdated(_ patch: HerdrMousePatchCopy.PatchAfterUpdate) {
        restartReason = .herdrUpdated(patch)
    }

    func beginHerdrUpdate() {
        herdrUpdateInProgress = true
        pendingConfirmation = nil
    }

    func endHerdrUpdate() {
        herdrUpdateInProgress = false
    }

    func cancelPendingConfirmation() {
        pendingConfirmation = nil
    }

    func confirmPendingAction() {
        guard let pending = pendingConfirmation else { return }
        pendingConfirmation = nil
        guard !herdrUpdateInProgress else { return }
        lastErrorMessage = nil
        bannerErrorMessage = nil
        switch pending.action {
        case .install: performInstall(startedFromBanner: pending.source == .banner)
        case .revert: performRevert()
        case .restartServer: performServerRestart()
        }
    }

    /// `--expected-version` makes the new server refuse the handoff, and the
    /// old one keep running, if the binary on disk changed in between.
    private func performServerRestart() {
        guard needsServerRestart, !serverRestarting, let binaryPath = resolveBinaryPath(), let version = binaryVersion else {
            return
        }
        serverRestartError = nil
        serverRestarting = true
        serverRestartTask = Task { [runner] in
            let result = await runner.run(
                binaryPath, HerdrUpdateRun.liveHandoffArguments(binaryPath: binaryPath, expectedVersion: version)
            )
            if HerdrUpdateRun.handedOff(status: result.status, output: result.output) {
                relaunch()
                return
            }
            serverRestarting = false
            serverRestartError = HerdrMousePatchCopy.serverRestartFailure(
                HerdrServerRestart.failureReason(output: result.output)
            )
            checkServer()
        }
    }

    private func performInstall(startedFromBanner: Bool) {
        let version: String
        let isUpdate: Bool
        switch state {
        case .patchable(_, let patchable): (version, isUpdate) = (patchable, false)
        case .outdated(_, let outdated, _, _): (version, isUpdate) = (outdated, true)
        default:
            reprobe()
            return
        }
        guard let binaryPath = resolveBinaryPath(), let entry = catalog(version) else {
            reprobe()
            return
        }
        let throttle = HerdrPatchProgressThrottle()
        phase = .downloading(0)
        installTask = Task { [downloader, fileManager] in
            defer { phase = .idle; reprobe() }
            do {
                let artifact = try await downloader.fetch(entry) { fraction in
                    guard throttle.shouldReport(fraction) else { return }
                    Task { @MainActor in if case .downloading = self.phase { self.phase = .downloading(fraction) } }
                }
                // `herdr update` can replace the binary while the download
                // runs; the patch fetched for the old version must not land
                // over the new one.
                let current = probe(binaryPath, fileManager)
                let unchanged = isUpdate
                    ? current.hasBackup && entry.supersedes(sha256: current.sha256)
                    : !current.hasVerbs
                guard current.version == version, unchanged else { throw HerdrChanged() }
                phase = .installing
                if isUpdate {
                    try HerdrMousePatchInstaller.update(artifactPath: artifact, binaryPath: binaryPath, fileManager: fileManager)
                    serverRestartError = nil
                    restartReason = .updated
                } else {
                    try HerdrMousePatchInstaller.install(artifactPath: artifact, binaryPath: binaryPath, fileManager: fileManager)
                    serverRestartError = nil
                    restartReason = .installed
                }
            } catch {
                let message = Self.message(for: error)
                lastErrorMessage = message
                if startedFromBanner { bannerErrorMessage = message }
            }
        }
    }

    private struct HerdrChanged: Error {}

    private func performRevert() {
        guard let binaryPath = resolveBinaryPath() else { return }
        do {
            try HerdrMousePatchInstaller.revert(binaryPath: binaryPath, fileManager: fileManager)
            serverRestartError = nil
            restartReason = .restored
        } catch {
            lastErrorMessage = Self.message(for: error)
        }
        reprobe()
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
            return "The installed binary did not verify; the herdr that was there before is back."
        case HerdrMousePatchInstaller.InstallError.rollbackFailed:
            return "The installed binary did not verify, and putting the previous herdr back failed. Reinstall herdr before using it."
        case HerdrMousePatchInstaller.RevertError.verificationFailed:
            return "The reverted binary still carries the mouse verbs."
        case HerdrMousePatchInstaller.InstallError.backupMissing:
            return "flock's saved copy of the original herdr is missing, so it left this one alone."
        case HerdrMousePatchInstaller.RevertError.backupMissing:
            return "No backup is available to revert to."
        case HerdrMousePatchDownloader.Failure.transport:
            return "Couldn't download the patch. Check your connection and try again."
        case HerdrMousePatchDownloader.Failure.checksumMismatch:
            return "The download didn't match what flock expected. Nothing was changed."
        case is HerdrChanged:
            return "herdr changed while the patch downloaded. Nothing was changed."
        default:
            return "Something went wrong."
        }
    }
}
