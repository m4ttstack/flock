import FlockCore

/// Where a jump starts and how Jump Back returns, shared by the View menu,
/// the palette, the dock and mission control so every route records the
/// same origin.
@MainActor
struct JumpNavigator {
    let viewModel: SessionViewModel
    let drag: DragCoordinator
    let mode: AllWorkspacesModeStore

    var isInMissionControl: Bool {
        drag.isGridShown && mode.shown(dragInFlight: drag.activeSubject != nil) == .missionControl
    }

    var currentPlace: JumpPlace? {
        if isInMissionControl { return .missionControl }
        return viewModel.resolvedFocusedPaneID.map(JumpPlace.pane)
    }

    func openOldest() {
        let from = currentPlace
        if isInMissionControl {
            drag.closeGrid()
            Task { await viewModel.jumpToOldestAttentionToast(from: from) }
        } else {
            Task { await viewModel.jumpToOldestDisplayedAttentionToast(from: from) }
        }
    }

    func open(toast pane: PaneID) {
        let from = currentPlace
        drag.closeGrid()
        Task { await viewModel.jumpToAttentionToast(pane: pane, from: from) }
    }

    func open(pane: PaneID) {
        let from = currentPlace
        drag.closeGrid()
        Task { await viewModel.jumpToPane(pane, from: from) }
    }

    func back() {
        guard let target = viewModel.jumpBackTarget else { return }
        let from = currentPlace
        switch target {
        case .missionControl:
            viewModel.recordJump(from: from)
            mode.select(.missionControl)
            drag.openGrid()
        case .pane(let pane):
            open(pane: pane)
        }
    }
}
