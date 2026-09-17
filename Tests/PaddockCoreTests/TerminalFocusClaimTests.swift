import XCTest
@testable import PaddockCore

final class TerminalFocusClaimTests: XCTestCase {
    /// The focused pane takes first responder with nothing else asking for
    /// it, which is what makes a pane typeable with no extra click.
    func testTheFocusedPaneClaimsWhatItDoesNotAlreadyHold() {
        XCTAssertEqual(
            TerminalFocusClaim.decide(wantsFocus: true, editorIsOpen: false, holdsResponder: false), .claim
        )
    }

    /// The case this exists for, and the half a refusal to re-claim does not
    /// cover: the terminal is ALREADY holding first responder when the editor
    /// opens, so declining to take it again leaves the editor with nothing
    /// and the keystrokes in a shell.
    func testTheFocusedPaneStandsDownWhenAnEditorOpensWhileItHoldsFocus() {
        XCTAssertEqual(
            TerminalFocusClaim.decide(wantsFocus: true, editorIsOpen: true, holdsResponder: true), .standDown
        )
    }

    /// Once it has stood down there is nothing left to do, however many times
    /// the pass runs while the editor is up.
    func testAPaneThatHasAlreadyStoodDownDoesNothingMore() {
        XCTAssertEqual(
            TerminalFocusClaim.decide(wantsFocus: true, editorIsOpen: true, holdsResponder: false), .leaveAlone
        )
    }

    /// The heal-back: the editor closes, and the focused pane takes the
    /// keyboard again on the very next pass, so standing down can never
    /// strand it.
    func testTheFocusedPaneTakesFocusBackOnceTheEditorIsGone() {
        XCTAssertEqual(
            TerminalFocusClaim.decide(wantsFocus: true, editorIsOpen: false, holdsResponder: false), .claim
        )
        XCTAssertEqual(
            TerminalFocusClaim.decide(wantsFocus: true, editorIsOpen: false, holdsResponder: true), .leaveAlone
        )
    }

    /// An unfocused pane never claims, editor or no editor: that rule is
    /// older than this one and is not weakened by it. It stands down for an
    /// editor like any other holder, which is the state a pane left in after
    /// herdr's focus moved off it.
    func testAnUnfocusedPaneNeverClaimsAndStillYieldsToAnEditor() {
        XCTAssertEqual(
            TerminalFocusClaim.decide(wantsFocus: false, editorIsOpen: false, holdsResponder: false), .leaveAlone
        )
        XCTAssertEqual(
            TerminalFocusClaim.decide(wantsFocus: false, editorIsOpen: false, holdsResponder: true), .leaveAlone
        )
        XCTAssertEqual(
            TerminalFocusClaim.decide(wantsFocus: false, editorIsOpen: true, holdsResponder: true), .standDown
        )
        XCTAssertEqual(
            TerminalFocusClaim.decide(wantsFocus: false, editorIsOpen: true, holdsResponder: false), .leaveAlone
        )
    }
}
