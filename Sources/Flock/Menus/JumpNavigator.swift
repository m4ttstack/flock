import FlockCore

/// How every route opens a card or a pane: the View menu, the palette, the
/// dock and mission control. In Overview a card opens in the focused view
/// instead, which focuses it in herdr under the covered canvas. A route that
/// closes the grid lands on its own pane, so it forgets the focus Workspaces
/// would otherwise get back.
@MainActor
struct JumpNavigator {
    let viewModel: SessionViewModel
    let drag: DragCoordinator
    let mode: AllWorkspacesModeStore

    var isInMissionControl: Bool {
        drag.isGridShown && mode.shown(dragInFlight: drag.activeSubject != nil) == .missionControl
    }

    var isFocusedInOverview: Bool { isInMissionControl && drag.gridFocusedPane != nil }

    func openOldest() {
        if isInMissionControl {
            if let pane = viewModel.oldestAttentionPane { focus(pane) }
            return
        }
        viewModel.forgetWorkspacesFocus()
        drag.closeGrid()
        Task { await viewModel.jumpToOldestDisplayedAttentionToast() }
    }

    func open(toast pane: PaneID) {
        viewModel.forgetWorkspacesFocus()
        drag.closeGrid()
        Task { await viewModel.jumpToAttentionToast(pane: pane) }
    }

    func open(pane: PaneID) {
        if isInMissionControl {
            focus(pane)
        } else {
            jump(to: pane)
        }
    }

    /// The card the focused view's Next chip names, nil outside it.
    var nextCard: PaneID? {
        guard isFocusedInOverview else { return nil }
        return viewModel.attentionToasts.oldest(excluding: drag.gridFocusedPane)?.paneID
    }

    func openNext() {
        guard let pane = nextCard else { return }
        focus(pane)
    }

    func backToOverview() {
        guard isFocusedInOverview else { return }
        drag.unfocusGridPane()
    }

    private func focus(_ pane: PaneID) {
        guard viewModel.focusInOverview(pane: pane) else { return }
        mode.missionSelection = pane
        drag.focusGridPane(pane)
    }

    private func jump(to pane: PaneID) {
        viewModel.forgetWorkspacesFocus()
        drag.closeGrid()
        Task { await viewModel.jumpToPane(pane) }
    }
}
