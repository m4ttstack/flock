import CoreGraphics
import FlockCore

/// The All Workspaces grid's side of the coordinator. Every decision lives in
/// `AllWorkspacesGridState`; this only feeds it.
extension DragCoordinator {
    func toggleGrid() {
        updateGrid { $0.toggle() }
    }

    func openGrid() {
        updateGrid { $0.open() }
    }

    func closeGrid() {
        updateGrid { $0.close() }
    }

    func focusGridPane(_ pane: PaneID) {
        updateGrid { $0.focus(pane: pane) }
    }

    func unfocusGridPane() {
        updateGrid { $0.unfocus() }
    }

    func zoomGrid(into workspace: WorkspaceID) {
        updateGrid { $0.zoom(into: workspace) }
    }

    func unzoomGrid() {
        updateGrid { $0.unzoom() }
    }

    func selectGridPane(_ pane: PaneID) {
        updateGrid { $0.select(pane: pane) }
    }

    func deselectGridPane() {
        updateGrid { $0.deselect() }
    }

    /// The selected mini pane, held back for as long as a ghost is on
    /// screen, settle included: its outline would mark a pane the drop is
    /// not about.
    var gridSelection: PaneID? {
        activeSubject == nil ? gridSelectedPane : nil
    }
}

/// Only `ChromeRenderTests` calls these, from its tests of the preview card
/// Arrange no longer has. They go when those tests move to the selection.
extension DragCoordinator {
    func showGridPreview(pane: PaneID) {
        selectGridPane(pane)
    }

    var gridPreviewCard: PaneID? { gridSelection }

    func gridPaneFrame(of pane: PaneID) -> CGRect? {
        surfaces?.grid?.miniPaneFrame(of: pane)
    }
}
