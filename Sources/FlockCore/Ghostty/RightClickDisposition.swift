import Foundation

/// What a right click on a pane's ghostty surface should do, decided PURELY
/// from the click's own Option state, whether the pane app has asked for
/// mouse reporting, and whether the pane is flock's focused one -- no view,
/// event object, or libghostty call inside this type, so the decision is
/// testable with no `NSEvent`/`NSView` anywhere.
public enum RightClickDisposition: Equatable, Sendable {
    /// Present herdr's own action menu (Split/Close/...): `GhosttySurfaceView`
    /// hands the event back to the responder chain, which asks it for a menu
    /// via `menu(for:)` (built by its `paneMenuProvider`).
    case menu
    /// Send the click into the pane's own program. `GhosttySurfaceView`
    /// routes it through `MouseForwarding`, which turns it into a
    /// `terminal.mouse` line on the control FIFO (capture is on whenever this
    /// is returned).
    case forwardToPane
    /// Neither the menu nor the pane: rearrange mode owns the whole pane as a
    /// drag surface, so a right-click there does nothing on its own -- it is
    /// drag input like any other point on the pane.
    case suppressed

    /// The rule:
    /// - Rearrange mode active: always `.suppressed`, before anything else.
    /// - Not flock's focused pane: `.menu`. herdr reports mouse capture to
    ///   every attached pane, focused or not, and `MouseForwarding` drops
    ///   every event for an unfocused pane, so forwarding here would leave the
    ///   click with nowhere to go at all.
    /// - Focused, Option held: `.menu`.
    /// - Focused, capture ON: `.forwardToPane`. The program claimed the
    ///   mouse, so a plain right-click is its click.
    /// - Focused, capture OFF: `.menu`. Nothing is listening in the pane, so
    ///   the click falls through to the menu rather than disappearing into a
    ///   plain shell.
    ///
    /// Option means one thing and only one thing on a pane: force the menu.
    /// It is what keeps the menu reachable in a pane whose program is
    /// listening, which most agent panes are, and nothing else on this
    /// surface reads the modifier (see `RearrangeMode`).
    public static func decide(
        optionHeld: Bool,
        captureEnabled: Bool,
        paneIsFocused: Bool,
        rearrangeActive: Bool = false
    ) -> RightClickDisposition {
        guard !rearrangeActive else { return .suppressed }
        guard paneIsFocused, !optionHeld, captureEnabled else { return .menu }
        return .forwardToPane
    }
}
