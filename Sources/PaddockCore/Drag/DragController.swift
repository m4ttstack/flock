import CoreGraphics
import Observation

/// What committing a drag gesture's plan produced, mirroring
/// `SessionViewModel.perform(subject:target:)`'s three outcomes so
/// `DragController` can drive its own phase from the same vocabulary the
/// view model already reports through `noticeSink`.
public enum DragOutcome: Equatable, Sendable {
    case committed
    case noOp
    case rejected(String)
}

/// Runs a resolved `(DragSubject, DropTarget)` pair for real. The
/// production seam is `SessionViewModel.perform(subject:target:)`; the
/// controller never plans or executes anything itself.
public typealias DragCommit = @MainActor (DragSubject, DropTarget) async -> DragOutcome

/// Reveals `target`'s tab or workspace so the user can drop inside it. Fired
/// once per dwell; the drag itself stays in `.dragging` while this runs.
public typealias SpringLoadAction = @MainActor (DropTarget) async -> Void

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

    private let commit: DragCommit
    private let springLoadAction: SpringLoadAction
    private let now: @MainActor () -> ContinuousClock.Instant

    public init(
        commit: @escaping DragCommit,
        springLoadAction: @escaping SpringLoadAction = { _ in },
        now: @escaping @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.commit = commit
        self.springLoadAction = springLoadAction
        self.now = now
    }

    public func began(_ subject: DragSubject, at point: CGPoint) {
        phase = .dragging(subject, ghostPosition: point, target: nil)
        springLoad = nil
        springLoadFired = false
    }

    public func moved(to point: CGPoint, surfaces: DropSurfaces) {
        guard case .dragging(let subject, _, _) = phase else { return }
        let target = resolveDropTarget(at: point, dragging: subject, surfaces: surfaces)
        phase = .dragging(subject, ghostPosition: point, target: target)
        updateSpringLoad(for: target)
        fireSpringLoadIfDue()
    }

    /// Space: fires the pending dwell immediately, once, without waiting for
    /// its deadline.
    public func forceSpringLoad() {
        guard let armed = springLoad, !springLoadFired else { return }
        fire(armed.target)
    }

    /// Resolves the current target's plan through `commit` and settles the
    /// phase from its `DragOutcome`. A nil target (never resolved to
    /// anything droppable) and a `.noOp` outcome both spring back to `.idle`
    /// silently -- `commit` is never called for the former since there is
    /// nothing to plan.
    public func ended() async {
        guard case .dragging(let subject, _, let target) = phase else { return }
        guard let target else {
            phase = .idle
            return
        }
        phase = .committing
        switch await commit(subject, target) {
        case .committed, .noOp:
            phase = .idle
        case .rejected(let reason):
            phase = .rejected(reason: reason)
        }
    }

    /// Returns to `.idle` from any phase, including `.committing` (its
    /// result, once it lands, is simply discarded rather than reopening a
    /// gesture the user already abandoned) -- Esc always wins and issues no
    /// commit.
    public func cancelled() {
        phase = .idle
        springLoad = nil
        springLoadFired = false
    }

    private func updateSpringLoad(for target: DropTarget?) {
        guard let target, Self.springLoadEligible(target) else {
            springLoad = nil
            springLoadFired = false
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
        let action = springLoadAction
        Task { await action(target) }
    }

    private static func springLoadEligible(_ target: DropTarget) -> Bool {
        switch target {
        case .tabThumbnail, .workspaceThumbnail: return true
        case .paneEdge, .paneInterior, .tabStrip, .newTab, .newWorkspace, .workspaceRail: return false
        }
    }
}
