import Foundation

/// Whether an Esc press leaves the chat popover, and how far: only the press
/// that actually leaves a level is spent, mirroring
/// `RearrangeModeMachine.handleEscape`'s own precedence -- one press, one
/// level, never two. Drilled into a feature sub-view, that level is the
/// chevron's own destination (back to the status root); already at the root,
/// it is the popover itself.
public enum ChatPopoverEsc {
    public static func handle(isPresented: inout Bool, isDrilledIn: inout Bool) -> Bool {
        guard isPresented else { return false }
        if isDrilledIn {
            isDrilledIn = false
        } else {
            isPresented = false
        }
        return true
    }
}
