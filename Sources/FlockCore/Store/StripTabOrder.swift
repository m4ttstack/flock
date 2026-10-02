/// The order the window's strip draws a workspace's tabs in: open tabs, then
/// complete ones (`TabCompletionStore`), each run in herdr's own order.
/// herdr's order is never changed for it, which is what puts a tab back where
/// it was once its mark comes off.
public enum StripTabOrder {
    /// `leading`, when it is complete, heads the complete run for as long as
    /// it is passed: the strip lifts a selected complete tab there and lets it
    /// fall back once the selection moves on.
    public static func ordered(_ tabs: [TabRecord], isComplete: (TabID) -> Bool, leading: TabID? = nil) -> [TabRecord] {
        let complete = tabs.filter { isComplete($0.tabID) }
        let lifted = complete.filter { $0.tabID == leading } + complete.filter { $0.tabID != leading }
        return tabs.filter { !isComplete($0.tabID) } + lifted
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
