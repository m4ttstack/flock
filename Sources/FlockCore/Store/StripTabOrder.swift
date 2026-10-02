/// The order the window's strip draws a workspace's tabs in: open tabs, then
/// complete ones (`TabCompletionStore`), each run in herdr's own order.
/// herdr's order is never changed for it, which is what puts a tab back where
/// it was once its mark comes off.
public enum StripTabOrder {
    public static func ordered(_ tabs: [TabRecord], isComplete: (TabID) -> Bool) -> [TabRecord] {
        tabs.filter { !isComplete($0.tabID) } + tabs.filter { isComplete($0.tabID) }
    }

    /// herdr's `tab.move` takes an index into its own list. A slot before the
    /// strip's `stripIndex`th tab lands before that same tab; a slot past the
    /// last lands at herdr's end.
    public static func modelInsertIndex(forStripIndex stripIndex: Int, strip: [TabID], model: [TabID]) -> Int {
        guard stripIndex < strip.count, let index = model.firstIndex(of: strip[max(stripIndex, 0)]) else {
            return model.count
        }
        return index
    }
}
