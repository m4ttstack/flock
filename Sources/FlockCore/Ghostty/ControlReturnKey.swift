/// Ctrl-Return, which AppKit treats as the "show context menu" key equivalent
/// and so never delivers to `keyDown` unless the pane claims it first in
/// `performKeyEquivalent`. Upstream ghostty's surface does the same.
///
/// Takes the pieces of a key event rather than an `NSEvent` because FlockCore
/// carries no AppKit; the view unwraps the event at the call site.
public enum ControlReturnKey {
    /// Command is excluded so the menu bar still gets first look at its own
    /// key equivalents.
    public static func isTerminalInput(characters: String?, control: Bool, command: Bool) -> Bool {
        control && !command && characters == "\r"
    }
}
