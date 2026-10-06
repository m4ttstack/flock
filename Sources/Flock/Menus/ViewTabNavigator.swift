import FlockCore

/// The one place the title bar's tabs, the View menu and the palette switch
/// views, so they can never disagree about which tab is selected or what
/// choosing one does.
@MainActor
struct ViewTabNavigator {
    let drag: DragCoordinator
    let mode: AllWorkspacesModeStore

    var dragInFlight: Bool { drag.activeSubject != nil }

    var selected: ViewTab {
        ViewTab.selected(gridShown: drag.isGridShown, shownMode: mode.shown(dragInFlight: dragInFlight))
    }

    func choose(_ tab: ViewTab) {
        let steps = tab.steps(
            gridShown: drag.isGridShown, focused: drag.gridFocusedPane != nil, dragInFlight: dragInFlight
        )
        for step in steps {
            switch step {
            case .unfocus: drag.unfocusGridPane()
            case .select(let gridMode): mode.select(gridMode)
            case .openGrid: drag.openGrid()
            case .closeGrid: drag.closeGrid()
            }
        }
    }
}
