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

    /// Closes the grid in either mode, as a click on a card does.
    func openOldest() {
        let from = currentPlace
        let inMissionControl = isInMissionControl
        drag.closeGrid()
        if inMissionControl {
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

    var backTarget: JumpPlace? { viewModel.jumpBackTarget(from: currentPlace) }

    func back() {
        guard let target = backTarget else { return }
        let from = currentPlace
        switch target {
        case .missionControl:
            viewModel.recordJump(from: from, to: .missionControl)
            mode.select(.missionControl)
            drag.openGrid()
        case .pane(let pane):
            open(pane: pane)
        }
    }
}
