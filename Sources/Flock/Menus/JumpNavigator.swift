import FlockCore

/// Where a jump starts and how Jump Back returns, shared by the View menu,
/// the palette, the dock and mission control so every route records the
/// same origin. In Overview a card opens in the focused view instead, which
/// moves nothing in herdr and records no jump.
@MainActor
struct JumpNavigator {
    let viewModel: SessionViewModel
    let drag: DragCoordinator
    let mode: AllWorkspacesModeStore

    var isInMissionControl: Bool {
        drag.isGridShown && mode.shown(dragInFlight: drag.activeSubject != nil) == .missionControl
    }

    var isFocusedInOverview: Bool { isInMissionControl && drag.gridFocusedPane != nil }

    var currentPlace: JumpPlace? {
        if isInMissionControl { return .missionControl }
        return viewModel.resolvedFocusedPaneID.map(JumpPlace.pane)
    }

    func openOldest() {
        if isInMissionControl {
            if let pane = viewModel.oldestAttentionPane { focus(pane) }
            return
        }
        let from = currentPlace
        drag.closeGrid()
        Task { await viewModel.jumpToOldestDisplayedAttentionToast(from: from) }
    }

    func open(toast pane: PaneID) {
        let from = currentPlace
        drag.closeGrid()
        Task { await viewModel.jumpToAttentionToast(pane: pane, from: from) }
    }

    func open(pane: PaneID) {
        if isInMissionControl {
            focus(pane)
        } else {
            jump(to: pane)
        }
    }

    var backTarget: JumpPlace? {
        isFocusedInOverview ? .missionControl : viewModel.jumpBackTarget(from: currentPlace)
    }

    func back() {
        if isFocusedInOverview {
            drag.unfocusGridPane()
            return
        }
        guard let target = backTarget else { return }
        let from = currentPlace
        switch target {
        case .missionControl:
            viewModel.recordJump(from: from, to: .missionControl)
            mode.select(.missionControl)
            drag.openGrid()
        case .pane(let pane):
            jump(to: pane)
        }
    }

    private func focus(_ pane: PaneID) {
        guard viewModel.focusInOverview(pane: pane) else { return }
        mode.missionSelection = pane
        drag.focusGridPane(pane)
    }

    private func jump(to pane: PaneID) {
        let from = currentPlace
        drag.closeGrid()
        Task { await viewModel.jumpToPane(pane, from: from) }
    }
}
