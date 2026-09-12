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

    /// `optionHeld` is the click's own physical modifier, checked first and
    /// unconditionally: Option always means "send this click to the pane,
    /// one-shot," bypassing the persistent routing toggle in either
    /// direction. Without Option, the existing persistent toggle decides,
    /// same as before Option existed at all. `mode` is the pane's CURRENT
    /// bridge mode (`.control` only for the resolved-focused pane in this
    /// app) -- an Option click has nowhere to go on an `.observe` pane, so
    /// it drops rather than falling back to either other disposition.
    public static func decide(optionHeld: Bool, routingEnabled: Bool, mode: PaneMode) -> RightClickDisposition {
        if optionHeld {
            return mode == .control ? .forwardToPane : .drop
        }
        return routingEnabled ? .forwardToPane : .menu
    }
}
