/// ⌘1 and on carry two meanings and are bound once: the View menu owns the
/// first three as Workspaces, Overview and Arrange, and a pane offering the
/// launcher borrows them. The choice is made as the key lands, never by
/// moving the key equivalent between menu items.
public enum DigitKeyDispatch {
    public enum Outcome: Equatable {
        case launch(slot: Int)
        case view(index: Int)
        case none
    }

    /// Workspaces, Overview, Arrange.
    public static let viewDigits = 3

    public static func decide(launcherShowing: Bool, index: Int) -> Outcome {
        if launcherShowing { return .launch(slot: index) }
        return index < viewDigits ? .view(index: index) : .none
    }
}
