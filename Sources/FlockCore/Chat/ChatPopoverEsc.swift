import Foundation

/// Whether an Esc press closes the chat popover: only the press that actually
/// dismisses something is spent, mirroring `RearrangeModeMachine.handleEscape`.
/// A popover carries no drag-in-progress complication, so the whole decision
/// is one guard: closed already, this press has somewhere else to be.
public enum ChatPopoverEsc {
    public static func handle(isPresented: inout Bool) -> Bool {
        guard isPresented else { return false }
        isPresented = false
        return true
    }
}
