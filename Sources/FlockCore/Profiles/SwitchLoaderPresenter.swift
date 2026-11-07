import Foundation
import Observation

/// Decides when the switch loader covers the window and holds its run. Lives
/// beside the profile controller rather than in a session, so the rebuild a
/// switch makes neither restarts the run nor drops it.
@MainActor
@Observable
public final class SwitchLoaderPresenter {
    /// What the window is in right now. During `switchPending` the old
    /// session is still being torn down, and `input` describes the target.
    public struct Snapshot: Equatable, Sendable {
        public var input: SwitchLoaderInput
        public var switchPending: Bool
        /// The controller's generation: a new one is a new session, which has
        /// not been live yet.
        public var generation: Int

        public init(input: SwitchLoaderInput, switchPending: Bool, generation: Int) {
            self.input = input
            self.switchPending = switchPending
            self.generation = generation
        }
    }

    /// What the loader names for a built session. After a server change it
    /// names the server, so a rebuild that lands before any pending snapshot
    /// is drawn still titles the run by the server switched to.
    public static func label(
        for profile: FlockProfile, serverLabel: String, isRemoteMachine: Bool, lastChangeWasServer: Bool
    ) -> String {
        if isRemoteMachine { return profile.machine?.label ?? serverLabel }
        return lastChangeWasServer ? serverLabel : profile.name
    }

    public private(set) var run: SwitchLoaderRun?
    /// The loader is fully opaque: what it covers need not be drawn. False
    /// while it fades in over the window and once it starts fading out.
    public private(set) var coversWindow = false
    /// Nothing on the loader moves, so its clock may stop.
    public private(set) var isSettled = false

    /// The window under the loader must take no input, though it may still
    /// show through the fade in.
    public var blocksInput: Bool { run.map { !$0.isFinishing } ?? false }

    @ObservationIgnored private let now: () -> Double
    @ObservationIgnored private let sleep: @Sendable (Double) async -> Void
    @ObservationIgnored private var nextID = 0
    @ObservationIgnored private var generation: Int?
    @ObservationIgnored private var hasBeenLive = false
    @ObservationIgnored private var switchUnderway = false
    @ObservationIgnored private var timers: [Task<Void, Never>] = []

    public init(
        now: @escaping () -> Double = { Date().timeIntervalSinceReferenceDate },
        sleep: @escaping @Sendable (Double) async -> Void = { try? await Task.sleep(for: .seconds($0)) }
    ) {
        self.now = now
        self.sleep = sleep
    }

    public func update(_ snapshot: Snapshot) {
        if snapshot.generation != generation {
            // A rebuild is a switch even when no pending snapshot was drawn
            // between the switch starting and the rebuild landing.
            if generation != nil { switchUnderway = true }
            generation = snapshot.generation
            hasBeenLive = false
        }
        if snapshot.switchPending { switchUnderway = true }
        var input = snapshot.input
        input.isSwitching = switchUnderway
        let model = SwitchLoaderModel.make(input)
        let wasLive = hasBeenLive
        if !snapshot.switchPending, input.store == .live { hasBeenLive = true }
        if model == nil || model?.phase == .done, !snapshot.switchPending { switchUnderway = false }

        let time = now()
        if let current = run, !current.isFinishing {
            var next = current
            if let model {
                next.apply(model, at: time - current.startedAt)
            } else {
                next.finish(at: time - current.startedAt, waitForBreath: false)
            }
            replace(with: next)
            return
        }
        guard let model, model.phase != .done else { return }
        let machineNeedsIt = input.isMachine && (!wasLive || isNotRunning(input.store))
        guard input.isSwitching || machineNeedsIt else { return }
        start(model, at: time)
    }

    private func start(_ model: SwitchLoaderModel, at time: Double) {
        cancelTimers()
        nextID += 1
        let id = nextID
        coversWindow = false
        replace(with: SwitchLoaderRun(id: id, startedAt: time, model: model))
        schedule(after: SwitchLoaderRun.Timing.appear, id: id) { presenter in
            guard presenter.run?.isFinishing == false else { return }
            presenter.coversWindow = true
        }
    }

    /// Stores the run and keeps the flags and timers that follow from it.
    private func replace(with next: SwitchLoaderRun) {
        let previous = run
        guard next != previous else { return }
        run = next
        if next.isFinishing {
            coversWindow = false
            if previous?.isFinishing != true, let ends = next.endsAt {
                schedule(after: ends - (now() - next.startedAt), id: next.id) { presenter in
                    presenter.run = nil
                    presenter.isSettled = false
                    presenter.cancelTimers()
                }
            }
        }
        isSettled = false
        if let settles = next.settlesAt {
            let version = next
            schedule(after: settles - (now() - next.startedAt), id: next.id) { presenter in
                guard presenter.run == version else { return }
                presenter.isSettled = true
            }
        }
    }

    private func schedule(after delay: Double, id: Int, _ action: @escaping @MainActor (SwitchLoaderPresenter) -> Void) {
        let sleep = sleep
        timers.append(Task { [weak self] in
            await sleep(max(delay, 0))
            guard !Task.isCancelled, let self, self.run?.id == id else { return }
            action(self)
        })
    }

    private func cancelTimers() {
        timers.forEach { $0.cancel() }
        timers = []
    }

    private func isNotRunning(_ store: ConnectionState) -> Bool {
        if case .notRunning = store { return true }
        return false
    }
}
