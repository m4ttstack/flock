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

    /// Every pointer report over a mini pane. A report that starts a wait
    /// replaces whatever wait was running; one that shows a card outright
    /// ends the grace the pane it came from armed.
    func gridHoverMoved(pane: PaneID) {
        switch updateGrid({ $0.hoverMoved(pane: pane) }) {
        case .unchanged:
            break
        case .shows:
            gridHoverIntent?.cancel()
            gridHoverGrace?.cancel()
        case .waits:
            gridHoverGrace?.cancel()
            gridHoverIntent?.cancel()
            gridHoverIntent = Task { [weak self] in
                try? await Task.sleep(for: AllWorkspacesGridState.hoverIntentDelay)
                guard !Task.isCancelled else { return }
                self?.gridHoverIntentElapsed(pane: pane)
            }
        }
    }

    func gridHoverIntentElapsed(pane: PaneID) {
        updateGrid { $0.hoverIntentElapsed(pane: pane) }
    }

    /// An exit reported after the neighbor's entry leaves the neighbor's wait
    /// running.
    func gridHoverEnded(pane: PaneID) {
        if grid.pendingHover == pane {
            gridHoverIntent?.cancel()
        }
        guard updateGrid({ $0.hoverEnded(pane: pane) }) else { return }
        armGridHoverGrace()
    }

    func gridHoverCardEntered() {
        gridHoverGrace?.cancel()
        updateGrid { $0.cardEntered() }
    }

    func gridHoverCardExited() {
        guard updateGrid({ $0.cardExited() }) else { return }
        armGridHoverGrace()
    }

    func gridHoverGraceElapsed() {
        updateGrid { $0.hoverGraceElapsed() }
    }

    /// The hovered pane's box on screen, in the drag space. Read live rather
    /// than captured when the card opened: the grid scrolls and its cards
    /// expand under a still pointer.
    func gridPaneFrame(of pane: PaneID) -> CGRect? {
        surfaces?.grid?.miniPaneFrame(of: pane)
    }

    /// Held back for as long as a ghost is on screen, settle included.
    var gridHoverCard: PaneID? {
        guard gridHover != nil else { return nil }
        return grid.hoverCard(dragInFlight: activeSubject != nil)
    }

    private func armGridHoverGrace() {
        gridHoverGrace?.cancel()
        gridHoverGrace = Task { [weak self] in
            try? await Task.sleep(for: AllWorkspacesGridState.hoverCardGrace)
            guard !Task.isCancelled else { return }
            self?.gridHoverGraceElapsed()
        }
    }
}
