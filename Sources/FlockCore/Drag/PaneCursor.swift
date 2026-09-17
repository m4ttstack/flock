import CoreGraphics

/// Which cursor image a pane-body hover/cursorUpdate callback should show.
/// `.passthrough` means leave whatever is already showing alone -- normally
/// whatever libghostty's own hover-shape callback last set (an I-beam over
/// text, a pointing hand over a link, and so on).
public enum PaneCursorKind: Equatable, Sendable {
    case openHand
    case closedHand
    case passthrough
}

public enum PaneCursor {
    /// `paneDragInProgress` wins outright over `rearrangeActive`: once a pane
    /// drag has started, the cursor is closed-hand for the WHOLE app, not
    /// only over the pane the drag began on -- the pointer is usually
    /// somewhere else by the time this fires. Otherwise `rearrangeActive`
    /// arms the whole body as a grab handle, matching
    /// `PaneGrabRegion.bodyArmsDrag`'s own rule. At rest neither applies, so
    /// the caller leaves the terminal's own cursor untouched.
    public static func forPaneBody(rearrangeActive: Bool, paneDragInProgress: Bool) -> PaneCursorKind {
        if paneDragInProgress { return .closedHand }
        return rearrangeActive ? .openHand : .passthrough
    }
}
