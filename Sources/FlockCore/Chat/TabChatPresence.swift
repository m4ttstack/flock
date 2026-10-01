/// Who is signed in to chat inside a tab, as one short line for the tab
/// switcher: the first signed-in pane's name, in reading order, and how many
/// more there are.
public enum TabChatPresence {
    /// `buddies` is a `peek`'s list keyed by each buddy's own pane.
    public static func label(for tab: TabRecord, in model: SessionModel, buddies: [PaneID: ChatBuddy]) -> String? {
        let present = panesInReadingOrder(tab, in: model).compactMap { buddies[$0] }
        guard let first = present.first else { return nil }
        return present.count == 1 ? first.displayName : "\(first.displayName) · \(present.count - 1) more"
    }

    /// Top to bottom, then left to right, by the tab's layout; a pane the
    /// layout does not place yet comes after, by id.
    private static func panesInReadingOrder(_ tab: TabRecord, in model: SessionModel) -> [PaneID] {
        let rects = Dictionary(
            (model.layouts[tab.tabID]?.panes ?? []).map { ($0.paneID, $0.rect) }, uniquingKeysWith: { first, _ in first }
        )
        return model.panes.values.filter { $0.tabID == tab.tabID }.map(\.paneID).sorted { a, b in
            let keyA = (rects[a] == nil ? 1 : 0, rects[a]?.y ?? 0, rects[a]?.x ?? 0, a.rawValue)
            let keyB = (rects[b] == nil ? 1 : 0, rects[b]?.y ?? 0, rects[b]?.x ?? 0, b.rawValue)
            return keyA < keyB
        }
    }
}
