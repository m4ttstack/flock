import Foundation

/// Which button a click arrived on -- as much of an `NSEvent` as the decision
/// below needs, so that decision carries no AppKit type and can be tested
/// without constructing an event.
public enum ClickButton: Equatable, Sendable {
    case primary
    case secondary
    /// Anything else a tap handler can be handed (a tablet or middle button,
    /// a key event), which is never a context-menu click.
    case other
}

/// Whether a tap handler is really looking at a context-menu click.
///
/// SwiftUI's `onTapGesture` on macOS fires for the SECONDARY button as well
/// as the primary one, so every tap handler that does something on click --
/// focus a pane, select a tab, open a rename editor, create a tab -- also
/// runs on a right-click that was only ever meant to open the context menu.
/// Each one asks this first and returns.
public enum SecondaryClick {
    /// The secondary button is secondary; so is a Control-held primary click,
    /// which is macOS's own second way to ask for a context menu and reaches
    /// a tap handler as an ordinary left click.
    public static func isSecondary(button: ClickButton, controlHeld: Bool) -> Bool {
        switch button {
        case .secondary: true
        case .primary: controlHeld
        case .other: false
        }
    }
}
