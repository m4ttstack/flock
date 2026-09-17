import CoreGraphics
import Observation

/// Commits a divider drag's final ratio. The production seam is
/// `SessionViewModel.setSplitRatio(tab:path:ratio:)`.
public typealias SplitRatioCommit = @MainActor (TabID, [Bool], Double) async -> Void

/// The AppKit-free half of a divider drag: `DividerDragMachine`, the live
/// footprint override the canvas lays out from, and the one ratio commit a
/// release after a real move owes. `DividerDragCoordinator` feeds it pointer,
/// release, Esc and resign-active events and owns the cursor and event
/// monitors around it.
@MainActor
@Observable
public final class DividerDragSession {
    /// The live footprint preview's own input to `CanvasGeometry`: the tab,
    /// path and ratio of whichever divider is currently being dragged, or
    /// `nil` at rest.
    public private(set) var liveOverride: (tabID: TabID, path: [Bool], ratio: Double)?

    private var machine = DividerDragMachine()
    /// Bumped by every `began` and by `cancel`/`abandon`, so a commit's own
    /// override clear, which resolves after the machine has already gone back
    /// to idle, can tell whether it still belongs to the CURRENT drag and
    /// never clears a newer drag's live preview. The mutation itself
    /// (`setSplitRatio`, and its own undo-journal entry) always runs
    /// regardless: it is the user's real, already-decided action.
    private var generation = 0
    @ObservationIgnored private let commit: SplitRatioCommit
    /// The commit the latest real release started, so a test can await it.
    @ObservationIgnored public private(set) var pendingCommit: Task<Void, Never>?

    public init(commit: @escaping SplitRatioCommit) {
        self.commit = commit
    }

    public var isDragging: Bool { machine.isDragging }

    /// `divider` alone is enough: `DividerDragMachine.began` derives the start
    /// ratio from the divider's OWN current boundary. Returns whether the drag
    /// actually started.
    @discardableResult
    public func began(_ divider: DividerHandle) -> Bool {
        guard machine.began(divider) else { return false }
        generation += 1
        guard case .dragging(_, let start, _) = machine.phase else { return false }
        liveOverride = (divider.tabID, divider.path, start)
        return true
    }

    /// `pointer` is canvas-local, matching `divider.regionFrame`'s own space.
    /// A report from a divider that is NOT the one dragging is ignored: its
    /// pointer measured against the dragging divider's `regionFrame` would
    /// produce a ratio for a divider that never asked to move.
    public func moved(to pointer: CGPoint, for divider: DividerHandle) {
        guard case .dragging(let dragging, _, _) = machine.phase, dragging.tabID == divider.tabID, dragging.path == divider.path else { return }
        machine.moved(to: pointer)
        guard case .dragging(_, _, let live) = machine.phase else { return }
        liveOverride = (divider.tabID, divider.path, live)
    }

    /// Returns whether there was a gesture to end. A committed op holds
    /// `liveOverride` until the commit resolves: the optimistic overlay it
    /// triggers lands inside that call, and clearing first would snap back to
    /// the pre-drag layout for the main-actor hops in between.
    ///
    /// Reachable twice for the SAME release (the view's own `onEnded` and the
    /// coordinator's release monitor). The idle guard is what makes the second
    /// call a true no-op instead of clearing a still-in-flight commit's
    /// preview.
    @discardableResult
    public func ended() -> Bool {
        guard machine.phase != .idle else { return false }
        guard case let .setSplitRatio(tab, path, ratio)? = machine.ended() else {
            liveOverride = nil
            return true
        }
        let started = generation
        pendingCommit = Task {
            await self.commit(tab, path, ratio)
            guard self.generation == started else { return }
            self.liveOverride = nil
        }
        return true
    }

    /// Esc with the button still down.
    public func cancel() {
        generation += 1
        _ = machine.cancelled()
        liveOverride = nil
    }

    /// The app resigned active with the button still down: no release is
    /// ever coming.
    public func abandon() {
        generation += 1
        machine.abandoned()
        liveOverride = nil
    }
}
