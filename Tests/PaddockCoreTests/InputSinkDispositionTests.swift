import XCTest
@testable import PaddockCore

/// Pins the Step 2 brief invariant literally: "unfocused pane's input sink
/// receives nothing." `GhosttySurfaceView` gates `keyDown`/`insertText`/
/// `requestWindowFirstResponder` on exactly this decision (see F1/F14 in the
/// 18m review) -- the type itself is the honest, pure seam this can pin
/// without any real `NSView`/`NSEvent`.
final class InputSinkDispositionTests: XCTestCase {
    func testUnfocusedPaneInputSinkReceivesNothing() {
        XCTAssertEqual(InputSinkDisposition.decide(wantsFocus: false), .drop)
    }

    func testFocusedPaneInputSinkDelivers() {
        XCTAssertEqual(InputSinkDisposition.decide(wantsFocus: true), .deliver)
    }
}
