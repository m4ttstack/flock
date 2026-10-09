/// What the window shows under the palette. Every palette command names the
/// surfaces it is offered on, so a command that would act on something
/// hidden (the Workspaces selection behind the grid, a layout drawn as one
/// pane) is never listed there.
public enum PaletteSurface: CaseIterable, Sendable {
    /// The main canvas.
    case workspaces
    /// One pane opened from Overview, drawn alone.
    case overviewPane
    /// Overview's board of cards.
    case overview
    case arrange

    public static let everywhere = Set(allCases)

    public static func current(gridShown: Bool, shownMode: AllWorkspacesMode, paneShownInOverview: Bool) -> PaletteSurface {
        switch ViewTab.selected(gridShown: gridShown, shownMode: shownMode) {
        case .workspaces: .workspaces
        case .overview: paneShownInOverview ? .overviewPane : .overview
        case .arrange: .arrange
        }
    }

    /// Where ⌘K opens the palette: only over a pane the user is in. The
    /// board and Arrange have too little to offer to be worth a palette.
    public var opensPalette: Bool {
        switch self {
        case .workspaces, .overviewPane: true
        case .overview, .arrange: false
        }
    }

    public static func surfaces(of tab: ViewTab) -> Set<PaletteSurface> {
        Set(allCases.filter { ViewTab.of($0) == tab })
    }
}

private extension ViewTab {
    static func of(_ surface: PaletteSurface) -> ViewTab {
        switch surface {
        case .workspaces: .workspaces
        case .overviewPane, .overview: .overview
        case .arrange: .arrange
        }
    }
}
