/// flock's three peer views, switched by the title bar's tabs, the View menu
/// and the palette. Overview and Arrange are the All Workspaces grid's two
/// modes.
public enum ViewTab: String, CaseIterable, Sendable {
    case workspaces
    case overview
    case arrange

    public var title: String {
        switch self {
        case .workspaces: "Workspaces"
        case .overview: AllWorkspacesMode.missionControl.title
        case .arrange: AllWorkspacesMode.arrange.title
        }
    }

    public var symbolName: String {
        switch self {
        case .workspaces: "rectangle.split.2x1.fill"
        case .overview: "rectangle.split.3x1.fill"
        case .arrange: "square.grid.2x2.fill"
        }
    }

    /// The digit of its ⌥⌘ key, in tab order.
    public var digit: Character {
        switch self {
        case .workspaces: "1"
        case .overview: "2"
        case .arrange: "3"
        }
    }

    public var gridMode: AllWorkspacesMode? {
        switch self {
        case .workspaces: nil
        case .overview: .missionControl
        case .arrange: .arrange
        }
    }

    /// Derived, never stored: Workspaces while the grid is closed, otherwise
    /// the mode the grid draws. A focused pane is drawn by Overview, so it
    /// selects Overview.
    public static func selected(gridShown: Bool, shownMode: AllWorkspacesMode) -> ViewTab {
        guard gridShown else { return .workspaces }
        switch shownMode {
        case .missionControl: return .overview
        case .arrange: return .arrange
        }
    }

    public enum Step: Equatable, Sendable {
        case select(AllWorkspacesMode)
        case openGrid
        case closeGrid
    }

    /// What choosing `self` does, in order. Nothing during a drag, when the
    /// tabs are inert, and nothing for the tab already shown. Each grid mode
    /// keeps its own place: a pane focused in Overview stays focused while
    /// Arrange or Workspaces is shown, and choosing Overview returns to it.
    public func steps(gridShown: Bool, shownMode: AllWorkspacesMode, dragInFlight: Bool) -> [Step] {
        guard !dragInFlight else { return [] }
        guard self != Self.selected(gridShown: gridShown, shownMode: shownMode) else { return [] }
        switch self {
        case .workspaces: return [.closeGrid]
        case .overview: return [.select(.missionControl), .openGrid]
        case .arrange: return [.select(.arrange), .openGrid]
        }
    }
}
