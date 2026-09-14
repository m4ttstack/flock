import Foundation

/// What a right click on a pane's ghostty surface should do, decided PURELY
/// from the click's own Option state, whether the pane app has asked for
/// mouse reporting, and whether the pane is paddock's focused one -- no view,
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
    /// - Not paddock's focused pane: always `.menu`. herdr reports mouse
    ///   capture to every attached pane, focused or not, so capture alone
    ///   cannot decide this; `MouseForwarding` drops every event for an
    ///   unfocused pane, so forwarding one here would leave the click with
    ///   nowhere to go at all -- no menu and no delivery.
    /// - Focused, Option held: `.menu`. Option is the deliberate "give me the
    ///   herdr menu" gesture.
    /// - Focused, no Option, mouse capture ON: `.forwardToPane`. The pane app
    ///   claimed the click, so it gets it.
    /// - Focused, no Option, mouse capture OFF: `.menu`. Nothing is listening
    ///   in the pane, so fall through to the menu rather than drop the click
    ///   into a plain shell.
    ///
    /// Right-clicks land in the pane by default (focused, capture on) and
    /// Option summons the menu -- the inverse of a persistent per-pane toggle,
    /// which this replaces.
    public static func decide(
        optionHeld: Bool, captureEnabled: Bool, paneIsFocused: Bool, rearrangeActive: Bool = false
    ) -> RightClickDisposition {
        guard !rearrangeActive else { return .suppressed }
        guard paneIsFocused, !optionHeld, captureEnabled else { return .menu }
        return .forwardToPane
    }
}
