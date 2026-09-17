import Foundation

/// What a pane's terminal should do about the window's first responder on its
/// OWN initiative -- as it becomes the focused pane, and as its view enters a
/// window -- decided purely from whether it is the resolved-focused pane,
/// whether an inline editor is open anywhere in the window, and whether this
/// view is the one currently holding first responder.
///
/// A window has exactly one first responder, and the inline rename editor is
/// the only other thing in flock that wants it. That editor is opened by a
/// double-click on a label and then typed into, so a terminal that keeps
/// first responder while it is open does not merely interrupt the edit: the
/// keystrokes land in a live shell, which runs them.
///
/// Refusing to re-claim is not enough, which is the whole reason this carries
/// `holdsResponder`. The terminal of the focused pane is already holding
/// first responder when the editor opens, so a rule that only declines to
/// take it changes nothing at all: the editor asks for focus, the terminal
/// never gives it up, and the keys keep going to the shell. The terminal has
/// to stand down and leave the window with no first responder, which is the
/// state an editor's own focus request is answered from.
///
/// This decides the AUTOMATIC claim alone. A click into a pane body still
/// moves first responder there directly, which is how an open editor is
/// dismissed at all: it commits on losing focus, the way every macOS inline
/// rename does.
public enum TerminalFocusClaim: Equatable, Sendable {
    /// Take first responder.
    case claim
    /// Give it up, leaving the window holding none: an editor needs it and
    /// this view is what is in its way.
    case standDown
    /// Neither. Every state where the responder is already where it belongs.
    case leaveAlone

    public static func decide(wantsFocus: Bool, editorIsOpen: Bool, holdsResponder: Bool) -> TerminalFocusClaim {
        if editorIsOpen {
            return holdsResponder ? .standDown : .leaveAlone
        }
        return wantsFocus && !holdsResponder ? .claim : .leaveAlone
    }
}
