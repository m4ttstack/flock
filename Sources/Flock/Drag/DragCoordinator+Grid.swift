import CoreGraphics
import FlockCore

/// The All Workspaces grid's side of the coordinator. Every decision lives in
/// `AllWorkspacesGridState`; this only feeds it.
extension DragCoordinator {
    func toggleGrid() {
        updateGrid { $0.toggle() }
    }

    func closeGrid() {
        updateGrid { $0.close() }
    }

    func showGridPreview(pane: PaneID) {
        updateGrid { $0.showPreview(pane: pane) }
    }

    func dismissGridPreview() {
        updateGrid { $0.dismissPreview() }
    }

    /// The previewed pane's box on screen, in the drag space. Read live rather
    /// than captured when the card opened: the grid scrolls under a still
    /// card.
    func gridPaneFrame(of pane: PaneID) -> CGRect? {
        surfaces?.grid?.miniPaneFrame(of: pane)
    }

    /// Held back for as long as a ghost is on screen, settle included.
    var gridPreviewCard: PaneID? {
        guard gridPreview != nil else { return nil }
        return grid.previewCard(dragInFlight: activeSubject != nil)
    }
}
