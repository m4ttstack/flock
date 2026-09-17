import AppKit
import FlockCore

/// The AppKit half of `SecondaryClick`: reads the two things the rule needs
/// off the event SwiftUI is currently delivering. Every tap handler in the
/// chrome that acts on a click guards on this, since `onTapGesture` on macOS
/// fires for the secondary button too.
extension NSEvent {
    static func isSecondaryButtonEvent(_ event: NSEvent?) -> Bool {
        guard let event else { return false }
        return SecondaryClick.isSecondary(
            button: event.clickButton, controlHeld: event.modifierFlags.contains(.control)
        )
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
