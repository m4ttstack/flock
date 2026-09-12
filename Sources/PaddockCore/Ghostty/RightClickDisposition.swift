import Foundation

/// What a right click on a pane's ghostty surface should do, decided
/// PURELY from the click's own modifier state plus the two pieces of
/// standing pane state that already govern it -- no view, event object, or
/// libghostty call inside this type, so the decision itself is testable
/// with no `NSEvent`/`NSView` anywhere.
public enum RightClickDisposition: Equatable, Sendable {
    /// Present herdr's own action menu (Split/Close/routing toggle):
    /// `GhosttySurfaceView` hands the event back to the responder chain so
    /// SwiftUI's `.contextMenu` on `PaneCellView` shows it.
    case menu
    /// Send the click into the pane's program via
    /// `ghostty_surface_mouse_button`, with any `.option` bit stripped from
    /// the modifiers passed to ghostty first -- the pane sees a plain right
    /// click, not alt+right.
    case forwardToPane
    /// Neither: an Option-held right click on an observe-mode (unfocused)
    /// pane has nowhere to go (the bridge drops input in observe mode) and
    /// the user asked for a pane click, not a menu, so none shows.
    case drop

    /// RULING: forwarding -- whether asked for by the persistent routing
    /// toggle or by a one-shot Option click -- only ever actually reaches
    /// the pane on a `.control`-mode surface; on `.observe` it drops
    /// silently instead, NEVER falling back to `.menu`. Requesting the
    /// pane's own program is what the toggle (or Option) means, and an
    /// unfocused pane's bridge has no input path to deliver that to (see
    /// `GhosttySurfaceView.requestWindowFirstResponder`'s own gate) -- a
    /// menu on a routing-enabled pane would silently ignore the user's own
    /// standing choice.
    ///
    /// `optionHeld` is the click's own physical modifier, checked first:
    /// Option always means "send this click to the pane, one-shot,"
    /// overriding the persistent toggle for this one click regardless of
    /// what it is currently set to. Without Option, the toggle alone
    /// decides whether forwarding was even asked for.
    public static func decide(optionHeld: Bool, routingEnabled: Bool, mode: PaneMode) -> RightClickDisposition {
        let wantsForward = optionHeld || routingEnabled
        guard wantsForward else { return .menu }
        return mode == .control ? .forwardToPane : .drop
    }
}
