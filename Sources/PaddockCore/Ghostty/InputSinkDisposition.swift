import Foundation

/// Whether a pane's ghostty surface should accept input at all, decided
/// PURELY from `wantsFocus` -- the pane's own record of whether it is the
/// resolved-focused pane. The view-layer half of the three independent
/// unfocused-input guards `GhosttySurfaceView` enforces (the other two are
/// the bridge dropping stdin in observe mode, and herdr giving an observe
/// client no input path at all): a key event, an IME commit, or a request
/// to grab real AppKit first-responder status all check this before doing
/// anything, so an unfocused pane's input sink receives nothing even if
/// AppKit ever hands it first-responder status some other way (window
/// activation, Tab navigation) this view does not itself control.
public enum InputSinkDisposition: Equatable, Sendable {
    case deliver
    case drop

    public static func decide(wantsFocus: Bool) -> InputSinkDisposition {
        wantsFocus ? .deliver : .drop
    }
}
