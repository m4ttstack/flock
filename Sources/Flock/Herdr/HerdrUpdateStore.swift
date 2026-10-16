import FlockCore
import Foundation
import Observation

/// herdr's API does not report its own update check, so this reads the
/// manifest herdr itself reads. Any failure hides the note rather than
/// raising an error: it is a courtesy, not a feature someone is waiting on.
@MainActor
@Observable
final class HerdrUpdateStore {
    private(set) var latest: String?

    enum UpdatePhase: Equatable { case idle, updating }
    private(set) var updatePhase: UpdatePhase = .idle
    private(set) var updateError: String?
    private(set) var pendingUpdate: HerdrMousePatchCopy.Confirmation?
    /// The connected server can keep reporting the old version until Flock
    /// restarts, which would otherwise offer the finished update again.
    private var updatedTo: String?
    /// The handoff can bring the server's new version, or the patch store's
    /// new state, into `notice` and hide it before the run has finished.
    private var updatingNotice: HerdrUpdateNotice?

    @ObservationIgnored var updateTask: Task<Void, Never>?
    @ObservationIgnored private let patchStore: HerdrMousePatchStore
    @ObservationIgnored private let installedVersion: @MainActor () -> String?
    @ObservationIgnored private let fetchLatest: @Sendable () async -> String?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let runner: HerdrCommandRunner
    @ObservationIgnored private var lastCheck: Date?

    static let interval: TimeInterval = 60 * 60

    init(
        patchStore: HerdrMousePatchStore,
        installedVersion: @escaping @MainActor () -> String?,
        fetchLatest: @escaping @Sendable () async -> String? = HerdrUpdateStore.fetchFromHerdr,
        now: @escaping () -> Date = Date.init,
        runner: HerdrCommandRunner = ProcessHerdrCommandRunner()
    ) {
        self.patchStore = patchStore
        self.installedVersion = installedVersion
        self.fetchLatest = fetchLatest
        self.now = now
        self.runner = runner
    }

    var notice: HerdrUpdateNotice? {
        if let updatedTo, updatedTo == latest { return nil }
        let patchInstalled: Bool = if case .installed = patchStore.state { true } else { false }
        return HerdrUpdateNotice.decide(
            installed: installedVersion(), latest: latest, patchInstalled: patchInstalled,
            catalogHasLatest: latest.flatMap(HerdrMousePatchCatalog.entry(for:)) != nil, homebrew: isHomebrew
        )
    }

    /// What the pill and the Settings section draw: the notice the update
    /// started from while it runs, so its progress stays on screen.
    var displayedNotice: HerdrUpdateNotice? {
        if updatePhase == .updating, let updatingNotice { return updatingNotice }
        return notice
    }

    /// `herdr update` refuses to run on a Homebrew install.
    var canRunUpdate: Bool { patchStore.binaryPath != nil && !isHomebrew }

    /// A patch download or install is running; the update waits for it, so
    /// the binary is never replaced under an install.
    var isBlockedByPatchInstall: Bool { patchStore.phase != .idle }

    private var isHomebrew: Bool {
        patchStore.binaryPath.map {
            HerdrInstallKind.isHomebrew(resolvedPath: URL(fileURLWithPath: $0).resolvingSymlinksInPath().path)
        } ?? false
    }

    func checkIfDue() async {
        if let lastCheck, now().timeIntervalSince(lastCheck) < Self.interval { return }
        lastCheck = now()
        if let version = await fetchLatest() { latest = version }
    }

    func requestUpdate() {
        guard updatePhase == .idle, canRunUpdate, !isBlockedByPatchInstall, let notice else { return }
        pendingUpdate = HerdrUpdateRun.confirmation(for: notice)
    }

    func cancelUpdate() {
        pendingUpdate = nil
    }

    /// Runs the update, then, if flock's patch was on the herdr it replaced,
    /// puts the patch back on the new one before asking once for a restart.
    func confirmUpdate() {
        guard pendingUpdate != nil else { return }
        pendingUpdate = nil
        patchStore.reprobe()
        guard updatePhase == .idle, canRunUpdate, !isBlockedByPatchInstall,
              let binaryPath = patchStore.binaryPath, let target = latest else { return }
        let patchWasInstalled: Bool = if case .installed = patchStore.state { true } else { false }
        let before = patchStore.binaryIdentity()
        updateError = nil
        updatingNotice = notice
        updatePhase = .updating
        patchStore.beginHerdrUpdate()
        updateTask = Task { [runner, patchStore] in
            defer {
                patchStore.endHerdrUpdate()
                updatePhase = .idle
                updatingNotice = nil
            }
            let result = await runner.run(binaryPath, HerdrUpdateRun.arguments)
            let changed = patchStore.binaryIdentity() != before
            switch HerdrUpdateRun.outcome(status: result.status, output: result.output, binaryChanged: changed) {
            case .failed(let message):
                updateError = message
            case .notHandedOff:
                updateError = HerdrUpdateRun.notHandedOffMessage
            case .alreadyUpToDate(let onDisk):
                guard let running = installedVersion(), HerdrVersionOrder.isNewer(onDisk, than: running) == true else {
                    updateError = HerdrUpdateRun.notHandedOffMessage
                    return
                }
                let handoff = await runner.run(
                    binaryPath, HerdrUpdateRun.liveHandoffArguments(binaryPath: binaryPath, expectedVersion: onDisk)
                )
                guard HerdrUpdateRun.handedOff(status: handoff.status, output: handoff.output) else {
                    updateError = HerdrUpdateRun.serverBehindMessage
                    return
                }
                await finishHandoff(to: onDisk, patchWasInstalled: patchWasInstalled)
            case .updated:
                await finishHandoff(to: target, patchWasInstalled: patchWasInstalled)
            }
        }
    }

    /// Every bridge lost its server in the handoff, so the restart prompt
    /// goes up first and the reinstall's result refines it.
    private func finishHandoff(to version: String, patchWasInstalled: Bool) async {
        updatedTo = version
        patchStore.reprobe()
        guard patchWasInstalled, case .patchable = patchStore.state else {
            patchStore.noteHerdrUpdated(.untouched)
            return
        }
        patchStore.noteHerdrUpdated(.reinstalling)
        let reinstalled = await patchStore.reinstallAfterUpdate()
        patchStore.noteHerdrUpdated(reinstalled ? .reinstalled : .reinstallFailed)
    }

    nonisolated static func fetchFromHerdr() async -> String? {
        guard let (data, response) = try? await URLSession.shared.data(from: HerdrLatestManifest.url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return HerdrLatestManifest.version(from: data)
    }
}
