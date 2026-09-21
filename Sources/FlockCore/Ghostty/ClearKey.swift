/// Ctrl-L: readline's `clear-screen`, and the same binding in zsh, fish and
/// every shell flock is likely to be sitting in front of.
///
/// Recognising it is only ever a hint. flock does not clear anything and does
/// not know whether the program in the pane will either -- a full-screen TUI
/// takes Ctrl-L for itself and repaints. All this decides is that it is worth
/// looking at the pane's screen for a moment to find out
/// (`PaneLauncherRegistry.recordClearRequested`).
///
/// Takes the pieces of a key event rather than an `NSEvent` because FlockCore
/// carries no AppKit; the view unwraps the event at the call site.
public enum ClearKey {
    /// Control alone. Ctrl-Option-L and Ctrl-Shift-L are their own bindings in
    /// plenty of programs and mean nothing about clearing, so a stray modifier
    /// is a non-match rather than something to look past.
    public static func isClear(
        characters: String?, control: Bool, option: Bool, command: Bool, shift: Bool
    ) -> Bool {
        guard control, !option, !command, !shift else { return false }
        guard let characters, characters.count == 1 else { return false }
        return characters.lowercased() == "l"
    }
}
