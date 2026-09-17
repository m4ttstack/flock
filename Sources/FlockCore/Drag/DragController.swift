import CoreGraphics
import Observation

/// What committing a drag gesture's plan produced, mirroring
/// `SessionViewModel.perform(subject:target:)`'s outcomes so `DragController`
/// can drive its own phase from the same vocabulary the view model already
/// reports through `noticeSink`. `.notAttempted` is distinct from `.noOp`:
/// both spring the phase back to `.idle` silently, but `.noOp` means the plan
/// was legitimately a no-op (a pane dropped on itself) while `.notAttempted`
/// means the commit seam never had a model or executor to plan against at
/// all.
public enum DragOutcome: Equatable, Sendable {
    case committed
    case noOp
    case notAttempted
    case rejected(String)
}

/// Runs a resolved `(DragSubject, DropTarget)` pair for real. The
/// production seam is `SessionViewModel.perform(subject:target:)`; the
/// controller never plans or executes anything itself.
public typealias DragCommit = @MainActor (DragSubject, DropTarget) async -> DragOutcome

/// State machine for one drag-and-drop gesture, sitting between the pointer
/// events a view reports and the mutation path `DragCommit` runs.
///
/// `moved(to:surfaces:)` is the only place time is checked: a stationary
/// pointer during a real drag still delivers a steady stream of move events,
/// so an armed dwell fires as a side effect of the next such call rather
/// than from a timer the controller owns itself -- this is what keeps the
/// 500ms dwell testable against an injected clock with no `Task.sleep`.
@MainActor
@Observable
public final class DragController {
    public enum Phase: Equatable {
        case idle
        case dragging(DragSubject, ghostPosition: CGPoint, target: DropTarget?)
        case committing
        case rejected(reason: String)
    }

    private static let dwell: Duration = .milliseconds(500)

    public private(set) var phase: Phase = .idle
    public private(set) var springLoad: (target: DropTarget, deadline: ContinuousClock.Instant)?

    /// Distinct from `springLoad` being non-nil: `springLoad` stays set
    /// (deadline and all) after firing so the same target does not re-arm on
    /// its own. Only leaving the target and returning clears both.
    private var springLoadFired = false

    /// Bumped by `began()` and `cancelled()`, the two entry points that can
    /// start a new gesture (or definitively end one) while a previous
    /// `ended()` is still suspended on `commit`. `ended()` captures this
    /// before awaiting and only writes `phase` on resume if it is still
    /// current -- a commit that resolves after the gesture it belongs to was
    /// cancelled, or after a new gesture has already begun, still runs and
    /// still gets journaled by the executor; only its now-stale phase write
    /// is dropped.
    private var generation = 0

    private let commit: DragCommit
    /// Runs synchronously inside the call that fires the spring load, before
    /// `moved`/`forceSpringLoad` returns.
    private let onSpringLoad: @MainActor (DropTarget) -> Void
    private let now: @MainActor () -> ContinuousClock.Instant

    public init(
        commit: @escaping DragCommit,
        onSpringLoad: @escaping @MainActor (DropTarget) -> Void = { _ in },
        now: @escaping @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.commit = commit
        self.onSpringLoad = onSpringLoad
        self.now = now
    }

    public func began(_ subject: DragSubject, at point: CGPoint) {
        generation += 1
        phase = .dragging(subject, ghostPosition: point, target: nil)
        clearSpringLoad()
    }

    public func moved(to point: CGPoint, surfaces: DropSurfaces) {
        guard case .dragging(let subject, _, _) = phase else { return }
        let target = resolveDropTarget(at: point, dragging: subject, surfaces: surfaces)
        phase = .dragging(subject, ghostPosition: point, target: target)
        updateSpringLoad(for: target)
        fireSpringLoadIfDue()
    }

    /// Space: fires the pending dwell immediately, once, without waiting for
    /// its deadline. Guarded to `.dragging` because `springLoad` itself can
    /// still be armed and unfired while `.committing` (it is only cleared
    /// once the commit resolves), and firing a reveal action with no drag on
    /// screen to receive it would be observable nonsense.
    public func forceSpringLoad() {
        guard case .dragging = phase else { return }
        guard let armed = springLoad, !springLoadFired else { return }
        fire(armed.target)
    }

    /// Resolves the current target's plan through `commit` and settles the
    /// phase from its `DragOutcome`, guarded by `generation` (see its doc
    /// comment) against a `began()`/`cancelled()` that ran while this was
    /// suspended. A nil target (never resolved to anything droppable) never
    /// reaches `commit` at all. Every non-stale path clears `springLoad` too
    /// -- otherwise a spring load armed just before the drop would still
    /// read as armed once the gesture that armed it is over, which
    /// `forceSpringLoad()`'s own `.dragging` guard cannot catch once `phase`
    /// itself has moved past `.dragging`.
    public func ended() async {
        guard case .dragging(let subject, _, let target) = phase else { return }
        guard let target else {
            phase = .idle
            clearSpringLoad()
            return
        }
        let startedGeneration = generation
        phase = .committing
        let outcome = await commit(subject, target)
        guard generation == startedGeneration else { return }
        switch outcome {
        case .committed, .noOp, .notAttempted:
            phase = .idle
        case .rejected(let reason):
            phase = .rejected(reason: reason)
        }
        clearSpringLoad()
    }

    /// Returns to `.idle` from any phase and issues no commit of its own.
    /// Bumps `generation`, so a commit already dispatched by an in-flight
    /// `ended()` still runs to completion and still gets journaled -- only
    /// its phase write on resume is discarded once it sees the generation
    /// has moved on, rather than reopening a gesture the user already
    /// abandoned.
    public func cancelled() {
        generation += 1
        phase = .idle
        clearSpringLoad()
    }

    private func updateSpringLoad(for target: DropTarget?) {
        guard let target, Self.springLoadEligible(target) else {
            clearSpringLoad()
            return
        }
        if let current = springLoad, current.target == target {
            return
        }
        springLoad = (target: target, deadline: now().advanced(by: Self.dwell))
        springLoadFired = false
    }

    private func fireSpringLoadIfDue() {
        guard let armed = springLoad, !springLoadFired, now() >= armed.deadline else { return }
        fire(armed.target)
    }

    private func fire(_ target: DropTarget) {
        springLoadFired = true
        onSpringLoad(target)
    }

    private func clearSpringLoad() {
        springLoad = nil
        springLoadFired = false
    }

    private static func springLoadEligible(_ target: DropTarget) -> Bool {
        switch target {
        case .tabThumbnail, .workspaceThumbnail, .moreTabs: return true
        case .paneEdge, .paneInterior, .tabStrip, .newTab, .newWorkspace, .workspaceRail: return false
        }
    }
}
