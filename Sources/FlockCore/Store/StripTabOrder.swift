import CoreGraphics

/// The order the window's strip draws a workspace's tabs in: open tabs, then
/// complete ones (`TabCompletionStore`), each run in herdr's own order.
/// herdr's order is never changed for it, which is what puts a tab back where
/// it was once its mark comes off.
public enum StripTabOrder {
    public static func ordered(_ tabs: [TabRecord], isComplete: (TabID) -> Bool) -> [TabRecord] {
        tabs.filter { !isComplete($0.tabID) } + tabs.filter { isComplete($0.tabID) }
    }

    /// The strip indices of the run `tab` is drawn in. A tab can only be
    /// ordered among its own run: its mark, not its position, decides the run.
    public static func run(of tab: TabID, strip: [TabID], complete: Set<TabID>) -> Range<Int> {
        let openCount = strip.filter { !complete.contains($0) }.count
        return complete.contains(tab) ? openCount..<strip.count : 0..<openCount
    }

    /// herdr's `tab.move` takes an index into its own list, where a complete
    /// tab can sit anywhere. So the end of the open run lands just after the
    /// last open tab: before the first complete tab could be anywhere earlier
    /// in herdr's list. Every other slot lands before the tab it sits before,
    /// and a slot past the last lands at herdr's end.
    public static func modelInsertIndex(
        forStripIndex stripIndex: Int, moving: TabID, strip: [TabID], model: [TabID], complete: Set<TabID>
    ) -> Int {
        let openEnd = run(of: moving, strip: strip, complete: complete).upperBound
        if !complete.contains(moving), stripIndex == openEnd, stripIndex > 0,
           let lastOpen = model.firstIndex(of: strip[stripIndex - 1]) {
            return lastOpen + 1
        }
        guard stripIndex < strip.count, let index = model.firstIndex(of: strip[max(stripIndex, 0)]) else {
            return model.count
        }
        return index
    }

    /// How far the item at `index` slides while the tab at `dragging` is held
    /// over gap `insertIndex`, all three in strip indices. Measured inside
    /// `run` alone: the free run before the complete group is not a gap
    /// between tabs, so it must not count toward any tab's advance.
    public static func displacement(
        forItemAt index: Int, dragging: Int, insertIndex: Int, run: Range<Int>, items: [CGRect]
    ) -> CGFloat {
        guard run.contains(index), run.contains(dragging), run.upperBound <= items.count else { return 0 }
        return ReshuffleOffset.blockDisplacement(
            forItemAt: index - run.lowerBound, blockIndices: [dragging - run.lowerBound],
            insertIndex: insertIndex - run.lowerBound, items: Array(items[run]), axis: .vertical
        )
    }
}
