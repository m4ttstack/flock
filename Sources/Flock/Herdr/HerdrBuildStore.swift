import FlockCore
import Foundation
import Observation

/// Installs and updates herdr from the mattstack fork's build list only.
/// Resolves herdr the way `HerdrToolStore` does, probes its bytes and
/// `--version`, and maps the probe and the list through FlockCore's
/// decision. A binary replaced out from under a stale answer is the ordinary
/// case, so `refresh()` re-probes whenever the file's identity on disk moved.
@MainActor
@Observable
final class HerdrBuildStore {
    private(set) var state: HerdrBuildState?
    private(set) var list: HerdrBuildList?
    private(set) var phase: Phase = .idle
    private(set) var pendingConfirmation: PendingConfirmation?
    private(set) var lastErrorMessage: String?
    /// An install begun from the banner that failed. The banner stays up to
    /// say so even when the failure took away the state that offered it.
    private(set) var bannerErrorMessage: String?
    private(set) var restartReason: HerdrBuildCopy.RestartReason?
    /// The herdr found by the last refresh; nil when none is on disk.
    private(set) var binaryPath: String?
    private(set) var binaryVersion: HerdrBuildVersion?
    private(set) var serverBinary: HerdrServerBinary = .unknown
    /// A live handoff is running; Flock relaunches when it lands.
    private(set) var serverRestarting = false
    private(set) var serverRestartError: String?
    private(set) var serverBehindDismissedFor: String?
    /// The newest build the install banner was waved away for.
    private(set) var offerDismissedFor: String?

    enum Phase: Equatable { case idle, downloading(Double), installing }

    /// The banner and the Settings row both watch this store, and each
    /// presents only the confirmations it asked for.
    struct PendingConfirmation: Equatable {
        enum Action: Equatable { case install(InstallOffer), restartServer }
        enum Source: Equatable { case banner, settings }
        let action: Action
        let confirmation: HerdrBuildCopy.Confirmation
        let source: Source
    }

    /// What an install confirmation answers for: the build it named, and the
    /// herdr it would replace.
    struct InstallOffer: Equatable {
        let newest: String
        let installPath: String
        let probe: HerdrBuildInstaller.Probe
    }

    @ObservationIgnored var installTask: Task<Void, Never>?
    @ObservationIgnored var listTask: Task<Void, Never>?
    @ObservationIgnored var serverCheckTask: Task<Void, Never>?
    @ObservationIgnored var serverRestartTask: Task<Void, Never>?
    @ObservationIgnored private let resolveBinaryPath: () -> String?
    @ObservationIgnored private let defaultInstallPath: String
    @ObservationIgnored private let fetchList: @Sendable () async -> HerdrBuildList?
    @ObservationIgnored private let downloader: HerdrBuildDownloader
    @ObservationIgnored private let fileManager: FileManager
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let readVersionOutput: (String) -> String?
    @ObservationIgnored private let arch: HerdrArch
    @ObservationIgnored private let now: () -> Date
    /// The socket of the server this Flock is on, nil when that server is not
    /// this Mac's (a machine session) and so not this herdr's to restart.
    @ObservationIgnored private let serverSocketPath: () -> String?
    @ObservationIgnored private let probeServer: @Sendable (String, String) -> HerdrServerBinary
    @ObservationIgnored private let runner: HerdrCommandRunner
    @ObservationIgnored private let relaunch: () -> Void
    /// herdr can appear by any route, rt setup or a hand install included,
    /// not only through this store.
    @ObservationIgnored private let onBinaryPathChanged: () -> Void
    @ObservationIgnored private var lastProbed: BinaryFingerprint?
    @ObservationIgnored private var lastProbe: HerdrBuildInstaller.Probe?
    /// When a fetch last brought back a list. A failed fetch leaves it, so
    /// the next refresh tries again.
    @ObservationIgnored private var lastListFetch: Date?
    /// Until the first fetch ends, however it ends.
    @ObservationIgnored private var listPending = true
    @ObservationIgnored private var listRefreshRunning = false
    @ObservationIgnored private var listFetchesStarted = 0
    @ObservationIgnored private var listFetchApplied = 0

    /// The probe reads all of herdr (over 20 MB) on the main actor, and the
    /// app calls `refresh()` on every activation; these stat fields change
    /// whenever anything the probe reports could have.
    struct BinaryFingerprint: Equatable {
        let binary: FileIdentity
        let isWritable: Bool
    }

    /// An install renames a new file over the old one, which always changes
    /// the inode; size and mtime catch a rewrite in place.
    struct FileIdentity: Equatable {
        let resolvedPath: String
        let inode: Int?
        let size: Int?
        let modified: Date?
    }

    private static let offerDismissedKey = "flock.herdrBuild.offerDismissedFor"
    private static let serverBehindDismissedKey = "flock.herdrBuild.serverBehindDismissedFor"
    private static let listMaxAge: TimeInterval = 60 * 60
    private static let integrationArguments = ["integration", "install", "claude"]

    init(
        resolveBinaryPath: @escaping () -> String? = { ToolPath.resolve("herdr") },
        defaultInstallPath: String = NSHomeDirectory() + "/.local/bin/herdr",
        fetchList: @escaping @Sendable () async -> HerdrBuildList? = HerdrBuildListFetcher.fetch,
        downloader: HerdrBuildDownloader = .standard,
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard,
        readVersionOutput: @escaping (String) -> String? = { HerdrVersionReader().read(binaryPath: $0) },
        arch: HerdrArch = .current,
        now: @escaping () -> Date = Date.init,
        serverSocketPath: @escaping () -> String? = { nil },
        probeServer: @escaping @Sendable (String, String) -> HerdrServerBinary = HerdrServerBinary.probe(socketPath:binaryPath:),
        runner: HerdrCommandRunner = ProcessHerdrCommandRunner(),
        relaunch: @escaping () -> Void = { AppRelaunch.relaunch() },
        onBinaryPathChanged: @escaping () -> Void = {}
    ) {
        self.resolveBinaryPath = resolveBinaryPath
        self.defaultInstallPath = defaultInstallPath
        self.fetchList = fetchList
        self.downloader = downloader
        self.fileManager = fileManager
        self.defaults = defaults
        self.readVersionOutput = readVersionOutput
        self.arch = arch
        self.now = now
        self.serverSocketPath = serverSocketPath
        self.probeServer = probeServer
        self.runner = runner
        self.relaunch = relaunch
        self.onBinaryPathChanged = onBinaryPathChanged
        serverBehindDismissedFor = defaults.string(forKey: Self.serverBehindDismissedKey)
        offerDismissedFor = defaults.string(forKey: Self.offerDismissedKey)
        refresh()
    }

    var shouldOfferBanner: Bool {
        HerdrBuildOffer.shouldOffer(state: state, dismissedFor: offerDismissedFor)
    }

    var showsBanner: Bool { shouldOfferBanner || bannerErrorMessage != nil }

    var availableUpdate: String? {
        guard case .outdated(_, _, let newest) = state else { return nil }
        return newest
    }

    /// The build on disk changes herdr's server, but the server still runs
    /// an older binary, so that half is missing until herdr restarts.
    var needsServerRestart: Bool {
        guard case .current = state, serverBinary == .other else { return false }
        return list?.build(matching: binaryVersion, sha256: lastProbe?.sha256)?.changesServer == true
    }

    /// Nil while an install runs: a relaunch would end it part way.
    var restartPrompt: HerdrBuildCopy.RestartReason? {
        guard phase == .idle else { return nil }
        return restartReason ?? (needsServerRestart ? .serverBehind : nil)
    }

    /// The row's prompt, less a server banner waved away for the build on
    /// disk. A newer build raises it again.
    var bannerRestartPrompt: HerdrBuildCopy.RestartReason? {
        guard let prompt = restartPrompt else { return nil }
        guard prompt == .serverBehind, let build = binaryVersion?.display else { return prompt }
        return serverBehindDismissedFor == build ? nil : prompt
    }

    func dismissServerBehindBanner() {
        guard let build = binaryVersion?.display else { return }
        defaults.set(build, forKey: Self.serverBehindDismissedKey)
        serverBehindDismissedFor = build
    }

    /// Silences the unprompted offer for the newest build only; the settings
    /// row still offers it.
    func dismissBannerOffer() {
        bannerErrorMessage = nil
        guard let state, let token = HerdrBuildOffer.dismissalToken(for: state) else { return }
        defaults.set(token, forKey: Self.offerDismissedKey)
        offerDismissedFor = token
    }

    /// Called on init, whenever the settings row appears, the app becomes
    /// active or the server's herdr version changes, since herdr can be
    /// replaced by hand between one look and the next.
    func refresh() {
        refresh(force: false)
        let stale = lastListFetch.map { now().timeIntervalSince($0) >= Self.listMaxAge } ?? true
        guard stale, !listRefreshRunning else { return }
        listRefreshRunning = true
        listTask = Task {
            await refreshList()
            listRefreshRunning = false
        }
    }

    /// Re-probes unconditionally: after flock itself changed the binary, a
    /// write inside the stat fields' resolution must not be missed.
    func reprobe() {
        refresh(force: true)
    }

    /// A failed fetch keeps the list already read, and a fetch that lands
    /// after a later-started one has landed is dropped.
    func refreshList() async {
        listFetchesStarted += 1
        let fetch = listFetchesStarted
        let fetched = await fetchList()
        listPending = false
        if let fetched, fetch > listFetchApplied {
            listFetchApplied = fetch
            lastListFetch = now()
            if list != fetched { list = fetched }
        }
        decide()
    }

    private var probeTarget: String { resolveBinaryPath() ?? defaultInstallPath }

    private func refresh(force: Bool) {
        let target = probeTarget
        let fingerprint = fingerprint(of: target)
        if force || fingerprint != lastProbed {
            lastProbe = probe(target)
            lastProbed = fingerprint
        }
        let found = lastProbe?.exists == true ? target : nil
        if binaryPath != found {
            binaryPath = found
            onBinaryPathChanged()
        }
        if binaryVersion != lastProbe?.version { binaryVersion = lastProbe?.version }
        decide()
        // The server can be restarted while the binary stays put.
        checkServer()
    }

    private func decide() {
        guard let probe = lastProbe else { return }
        let decided = HerdrBuildDecision.decide(
            binaryExists: probe.exists, version: probe.version, sha256: probe.sha256, list: list,
            listPending: listPending, arch: arch, installPath: probeTarget, isWritable: probe.isWritable
        )
        if state != decided { state = decided }
    }

    private func probe(_ path: String) -> HerdrBuildInstaller.Probe {
        HerdrBuildInstaller.probe(binaryPath: path, fileManager: fileManager, readVersionOutput: readVersionOutput)
    }

    /// Called on every refresh and whenever the connection changes, since
    /// either can move which binary the server runs.
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

    private func identity(of path: String) -> FileIdentity {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let attributes = try? fileManager.attributesOfItem(atPath: resolved)
        return FileIdentity(
            resolvedPath: resolved,
            inode: (attributes?[.systemFileNumber] as? NSNumber)?.intValue,
            size: (attributes?[.size] as? NSNumber)?.intValue,
            modified: attributes?[.modificationDate] as? Date
        )
    }

    private func fingerprint(of path: String) -> BinaryFingerprint {
        BinaryFingerprint(
            binary: identity(of: path),
            isWritable: fileManager.isWritableFile(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path)
        )
    }

    private var installOffer: InstallOffer? {
        guard let lastProbe else { return nil }
        switch state {
        case .stock(let installPath, _, let newest), .outdated(let installPath, _, let newest):
            return InstallOffer(newest: newest, installPath: installPath, probe: lastProbe)
        default:
            return nil
        }
    }

    /// Asks before replacing an existing herdr, every time.
    func requestInstall(source: PendingConfirmation.Source) {
        guard phase == .idle, let offer = installOffer else { return }
        let confirmation: HerdrBuildCopy.Confirmation
        if case .outdated = state {
            confirmation = HerdrBuildCopy.updateConfirmation(installPath: offer.installPath, newest: offer.newest)
        } else {
            confirmation = HerdrBuildCopy.installConfirmation(installPath: offer.installPath, newest: offer.newest)
        }
        pendingConfirmation = PendingConfirmation(action: .install(offer), confirmation: confirmation, source: source)
    }

    /// The missing-herdr screen's button is the consent, so this asks
    /// nothing more.
    func installMissing() {
        guard phase == .idle, case .missing = state, let lastProbe else { return }
        lastErrorMessage = nil
        performInstall(build: list?.newest, decidedFrom: lastProbe, startedFromBanner: false)
    }

    func requestServerRestart(source: PendingConfirmation.Source) {
        guard needsServerRestart, !serverRestarting, phase == .idle else { return }
        pendingConfirmation = PendingConfirmation(
            action: .restartServer, confirmation: HerdrBuildCopy.serverRestartConfirmation, source: source
        )
    }

    func cancelPendingConfirmation() {
        pendingConfirmation = nil
    }

    func confirmPendingAction() {
        guard let pending = pendingConfirmation else { return }
        pendingConfirmation = nil
        guard phase == .idle, !serverRestarting else { return }
        switch pending.action {
        case .install(let offer):
            // A dialog left open while the list or the herdr on disk moved on
            // named another build or another file; asking again names the
            // ones that would change.
            guard installOffer == offer, let build = list?.newest, build.version.display == offer.newest else { return }
            lastErrorMessage = nil
            bannerErrorMessage = nil
            performInstall(build: build, decidedFrom: offer.probe, startedFromBanner: pending.source == .banner)
        case .restartServer:
            lastErrorMessage = nil
            bannerErrorMessage = nil
            performServerRestart()
        }
    }

    /// `--expected-version` makes the new server refuse the handoff, and the
    /// old one keep running, if the binary on disk changed in between.
    private func performServerRestart() {
        guard needsServerRestart, !serverRestarting, let binaryPath, let version = binaryVersion?.display else { return }
        serverRestartError = nil
        serverRestarting = true
        serverRestartTask = Task { [runner] in
            let result = await runner.run(
                binaryPath, HerdrLiveHandoff.liveHandoffArguments(binaryPath: binaryPath, expectedVersion: version)
            )
            if HerdrLiveHandoff.handedOff(status: result.status, output: result.output) {
                relaunch()
                return
            }
            serverRestarting = false
            serverRestartError = HerdrBuildCopy.serverRestartFailure(HerdrServerRestart.failureReason(output: result.output))
            checkServer()
        }
    }

    /// `build` nil: no list is read yet, so the install fetches one first.
    private func performInstall(
        build confirmed: HerdrBuildList.Build?, decidedFrom: HerdrBuildInstaller.Probe, startedFromBanner: Bool
    ) {
        let restart: HerdrBuildCopy.RestartReason?
        let installPath: String
        switch state {
        case .missing(let path): (installPath, restart) = (path, nil)
        case .stock(let path, _, _): (installPath, restart) = (path, .installed)
        case .outdated(let path, _, _): (installPath, restart) = (path, .updated)
        default: return
        }
        let throttle = HerdrDownloadProgressThrottle()
        phase = .downloading(0)
        installTask = Task { [downloader, fileManager, listTask] in
            defer { phase = .idle; reprobe() }
            do {
                var newest = confirmed
                if newest == nil {
                    await listTask?.value
                    if list == nil { await refreshList() }
                    newest = list?.newest
                }
                guard let newest, let asset = newest.assets[arch] else { throw ListUnreadable() }
                let artifact = try await downloader.fetch(
                    url: asset.url, sha256: asset.sha256, fileName: HerdrBuildInstaller.fileName(for: newest.version, arch: arch)
                ) { fraction in
                    guard throttle.shouldReport(fraction) else { return }
                    Task { @MainActor in if case .downloading = self.phase { self.phase = .downloading(fraction) } }
                }
                // herdr can be replaced while the download runs; a decision
                // made about the old file must not land over the new one.
                let current = probe(installPath)
                guard current.exists == decidedFrom.exists, current.sha256 == decidedFrom.sha256 else { throw HerdrChanged() }
                phase = .installing
                try HerdrBuildInstaller.install(
                    artifactPath: artifact, binaryPath: installPath, sha256: asset.sha256, fileManager: fileManager
                )
                try? fileManager.removeItem(atPath: artifact)
                if !decidedFrom.exists {
                    let result = await runner.run(installPath, Self.integrationArguments)
                    if result.status != 0 { lastErrorMessage = HerdrBuildCopy.integrationFailed }
                }
                serverRestartError = nil
                restartReason = restart
            } catch {
                let message = Self.message(for: error)
                lastErrorMessage = message
                if startedFromBanner { bannerErrorMessage = message }
            }
        }
    }

    private struct HerdrChanged: Error {}
    private struct ListUnreadable: Error {}

    private static func message(for error: Error) -> String {
        switch error {
        case HerdrBuildDownloader.Failure.checksumMismatch, HerdrBuildInstaller.InstallError.checksumMismatch:
            HerdrBuildCopy.checksumMismatch
        case HerdrBuildInstaller.InstallError.destinationNotWritable:
            HerdrBuildCopy.notWritable
        case HerdrBuildInstaller.InstallError.renameFailed, HerdrBuildInstaller.InstallError.stagingFailed:
            HerdrBuildCopy.renameFailed
        case is HerdrChanged:
            HerdrBuildCopy.herdrChanged
        case is ListUnreadable:
            HerdrBuildCopy.listUnreadable
        default:
            HerdrBuildCopy.downloadFailed
        }
    }
}
