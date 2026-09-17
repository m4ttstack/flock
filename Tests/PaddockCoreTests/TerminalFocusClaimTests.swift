import XCTest
@testable import PaddockCore

final class TerminalFocusClaimTests: XCTestCase {
    /// The focused pane takes first responder with nothing else asking for
    /// it, which is what makes a pane typeable with no extra click.
    func testTheFocusedPaneClaimsFocusWhenNoEditorIsOpen() {
        XCTAssertEqual(TerminalFocusClaim.decide(wantsFocus: true, editorIsOpen: false), .claim)
    }

    /// The case this exists for: an inline rename editor is open, and the
    /// focused pane's own re-claim would take the keystrokes out of the field
    /// and run them in a shell.
    func testTheFocusedPaneYieldsWhileAnEditorIsOpen() {
        XCTAssertEqual(TerminalFocusClaim.decide(wantsFocus: true, editorIsOpen: true), .yield)
    }

    /// An unfocused pane never claims, editor or no editor: that rule is
    /// older than this one and is not weakened by it.
    func testAnUnfocusedPaneNeverClaims() {
        XCTAssertEqual(TerminalFocusClaim.decide(wantsFocus: false, editorIsOpen: false), .yield)
        XCTAssertEqual(TerminalFocusClaim.decide(wantsFocus: false, editorIsOpen: true), .yield)
    }
}
