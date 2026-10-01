/// What a tab is called wherever flock names it. A tab nobody named, holding
/// one pane, borrows that pane's title; `isFromPane` says the title is
/// borrowed, so the strip can mark it as such.
public struct TabTitle: Equatable, Sendable {
    public let text: String
    public let isFromPane: Bool

    public init(text: String, isFromPane: Bool) {
        self.text = text
        self.isFromPane = isFromPane
    }

    /// herdr labels a tab nobody named with its place in the strip, "1" for
    /// the first. Matched as any number rather than against that place: the
    /// place is neither the tab's public `number` nor fixed across a move,
    /// and a label caught between a move and its echo would read as a name.
    public static func isAutoNamed(_ label: String) -> Bool {
        label.allSatisfy(\.isASCII) && label.allSatisfy(\.isNumber)
    }

    public static func resolve(_ tab: TabRecord, in model: SessionModel) -> TabTitle {
        guard isAutoNamed(tab.label) else { return TabTitle(text: tab.label, isFromPane: false) }
        let panes = model.panes.values.filter { $0.tabID == tab.tabID }
        guard panes.count == 1, let pane = panes.first else { return TabTitle(text: tab.label, isFromPane: false) }
        return TabTitle(text: pane.displayTitle, isFromPane: true)
    }
}
