import Foundation

/// Whether a pane's terminal may take real AppKit first-responder status on
/// its OWN initiative -- the claim it makes as it becomes the focused pane,
/// or as its view re-enters the window -- decided purely from whether it is
/// the resolved-focused pane and whether an inline editor is open anywhere in
/// the window.
///
/// A window has exactly one first responder, and the inline rename editor is
/// the only other thing in paddock that wants it. That editor is opened by a
/// double-click on a label and then typed into, so a terminal that re-claims
/// focus while it is open does not merely interrupt the edit: the keystrokes
/// land in a live shell, which runs them. The editor's own lifetime is short
/// and entirely user-driven, so yielding for its duration costs the terminal
/// nothing.
///
/// This decides the AUTOMATIC claim alone. A click into a pane body still
/// moves first responder there, which is how an open editor is dismissed at
/// all: it commits on losing focus, the way every macOS inline rename does.
public enum TerminalFocusClaim: Equatable, Sendable {
    case claim
    case yield

    public static func decide(wantsFocus: Bool, editorIsOpen: Bool) -> TerminalFocusClaim {
        guard wantsFocus, !editorIsOpen else { return .yield }
        return .claim
    }
}
