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

    /// `herdr update` refuses to run on a Homebrew install.
    var canRunUpdate: Bool { patchStore.binaryPath != nil && !isHomebrew }

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
        guard updatePhase == .idle, canRunUpdate, let notice else { return }
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
        patchStore.refresh()
        guard updatePhase == .idle, canRunUpdate, let binaryPath = patchStore.binaryPath, let target = latest else { return }
        let patchWasInstalled: Bool = if case .installed = patchStore.state { true } else { false }
        updateError = nil
        updatePhase = .updating
        updateTask = Task { [runner, patchStore] in
            defer { updatePhase = .idle }
            let result = await runner.run(binaryPath, HerdrUpdateRun.arguments)
            switch HerdrUpdateRun.outcome(status: result.status, output: result.output) {
            case .failed(let message):
                updateError = message
            case .updated:
                patchStore.refresh()
                let reinstalled = patchWasInstalled ? await patchStore.reinstallAfterUpdate() : false
                patchStore.noteHerdrUpdated(patchReinstalled: reinstalled)
                updatedTo = target
            }
        }
    }

    nonisolated static func fetchFromHerdr() async -> String? {
        guard let (data, response) = try? await URLSession.shared.data(from: HerdrLatestManifest.url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return HerdrLatestManifest.version(from: data)
    }
}
