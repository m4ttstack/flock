import Foundation

/// What a click on a chrome row -- a rail workspace, a strip tab, a pane's
/// title -- asks for, read from the click itself.
///
/// The row carries ONE tap gesture, never a `count: 2` for rename over a
/// single tap for select: SwiftUI holds a single tap until a double tap on the
/// same view has failed, so a second gesture makes every plain click sit out
/// the system's double-click interval before anything moves. A lone tap
/// gesture has nothing to wait for, and the click count it needs is already on
/// the event it is handed.
public enum ChromeRowClick: Equatable, Sendable {
    case select
    case beginRename
    /// The click belongs to something else (the context menu), or the editor
    /// this click would open is already open from the click before it.
    case ignore

    /// `clickCount` is whatever the event carried, so `0` (no event at all, or
    /// one that has no click count to give) reads as the plain click that
    /// reached the handler rather than as a rename.
    public static func of(button: ClickButton, controlHeld: Bool, clickCount: Int) -> ChromeRowClick {
        guard !SecondaryClick.isSecondary(button: button, controlHeld: controlHeld) else { return .ignore }
        switch clickCount {
        case ...1: return .select
        case 2: return .beginRename
        default: return .ignore
        }
    }
}
