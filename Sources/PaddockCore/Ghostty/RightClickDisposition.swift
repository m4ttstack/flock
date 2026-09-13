import Foundation

/// What a right click on a pane's ghostty surface should do, decided PURELY
/// from the click's own Option state, whether the pane app has asked for
/// mouse reporting, and the pane's mode -- no view, event object, or
/// libghostty call inside this type, so the decision is testable with no
/// `NSEvent`/`NSView` anywhere.
public enum RightClickDisposition: Equatable, Sendable {
    /// Present herdr's own action menu (Split/Close/...): `GhosttySurfaceView`
    /// hands the event back to the responder chain so SwiftUI's
    /// `.contextMenu` on `PaneCellView` shows it.
    case menu
    /// Send the click into the pane's own program. `GhosttySurfaceView`
    /// routes it through `MouseForwarding`, which turns it into a
    /// `terminal.mouse` line on the control FIFO (capture is on whenever this
    /// is returned).
    case forwardToPane

    /// The rule:
    /// - Observe-mode pane: always `.menu`. The herdr action menu works on
    ///   any pane, and an unfocused pane has no input path to forward to.
    /// - Control-mode pane with Option held: always `.menu`. Option is the
    ///   deliberate "give me the herdr menu" gesture.
    /// - Control-mode pane, no Option, mouse capture ON: `.forwardToPane`.
    ///   The pane app claimed the click, so it gets it.
    /// - Control-mode pane, no Option, mouse capture OFF: `.menu`. Nothing is
    ///   listening in the pane, so fall through to the menu rather than drop
    ///   the click into a plain shell.
    ///
    /// Right-clicks land in the pane by default (capture on) and Option
    /// summons the menu -- the inverse of a persistent per-pane toggle, which
    /// this replaces.
    public static func decide(optionHeld: Bool, captureEnabled: Bool, mode: PaneMode) -> RightClickDisposition {
        guard mode == .control, !optionHeld, captureEnabled else { return .menu }
        return .forwardToPane
    }
}
