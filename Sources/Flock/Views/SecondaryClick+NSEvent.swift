import AppKit
import FlockCore

/// The AppKit half of `SecondaryClick` and `ChromeRowClick`: reads what those
/// rules need off the event SwiftUI is currently delivering. Every tap handler
/// in the chrome that acts on a click goes through one of these, since
/// `onTapGesture` on macOS fires for the secondary button too.
extension NSEvent {
    static func isSecondaryButtonEvent(_ event: NSEvent?) -> Bool {
        guard let event else { return false }
        return SecondaryClick.isSecondary(
            button: event.clickButton, controlHeld: event.modifierFlags.contains(.control)
        )
    }

    /// What a chrome row's single tap gesture should do about the click it is
    /// being handed -- `NSApp.currentEvent` at the moment the tap fires.
    static func chromeRowClick(_ event: NSEvent?) -> ChromeRowClick {
        guard let event else { return .select }
        return ChromeRowClick.of(
            button: event.clickButton, controlHeld: event.modifierFlags.contains(.control),
            clickCount: event.mouseClickCount
        )
    }

    /// `clickCount` raises on an event that is not a mouse click, so the type
    /// is checked before it is read; `0` is the rule's own "no count".
    private var mouseClickCount: Int {
        switch type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            clickCount
        default:
            0
        }
    }

    private var clickButton: ClickButton {
        switch type {
        case .rightMouseDown, .rightMouseUp, .rightMouseDragged:
            .secondary
        case .leftMouseDown, .leftMouseUp:
            .primary
        default:
            .other
        }
    }
}
