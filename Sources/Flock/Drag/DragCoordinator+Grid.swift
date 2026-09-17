import CoreGraphics
import FlockCore

/// The All Workspaces grid's side of the coordinator. Every decision lives in
/// `AllWorkspacesGridState`; this only feeds it and times the hover wait.
extension DragCoordinator {
    func toggleGrid() {
        updateGrid { $0.toggle() }
    }

    func closeGrid() {
        updateGrid { $0.close() }
    }

    func toggleGridCard(_ workspace: WorkspaceID) {
        updateGrid { $0.toggleExpanded(workspace) }
    }

    func retainGridCards(_ order: [WorkspaceID]) {
        updateGrid { $0.retain(order) }
    }

    /// Every pointer report over a mini pane, in the drag space. A report
    /// that starts a wait replaces whatever wait was running.
    func gridHoverMoved(pane: PaneID, pointer: CGPoint) {
        guard updateGrid({ $0.hoverMoved(pane: pane, pointer: pointer) }) else { return }
        gridHoverIntent?.cancel()
        gridHoverIntent = Task { [weak self] in
            try? await Task.sleep(for: AllWorkspacesGridState.hoverIntentDelay)
            guard !Task.isCancelled else { return }
            self?.gridHoverIntentElapsed(pane: pane)
        }
    }

    func gridHoverIntentElapsed(pane: PaneID) {
        updateGrid { $0.hoverIntentElapsed(pane: pane) }
    }

    /// An exit reported after the neighbor's entry leaves the neighbor's wait
    /// running.
    func gridHoverEnded(pane: PaneID) {
        if grid.pendingHover?.pane == pane {
            gridHoverIntent?.cancel()
        }
        updateGrid { $0.hoverEnded(pane: pane) }
    }

    /// Held back for as long as a ghost is on screen, settle included.
    var gridHoverCard: AllWorkspacesGridState.Hover? {
        guard gridHover != nil else { return nil }
        return grid.hoverCard(dragInFlight: activeSubject != nil)
    }
}
