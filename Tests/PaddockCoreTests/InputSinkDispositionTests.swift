import XCTest
@testable import PaddockCore

/// An unfocused pane's input sink must receive nothing: `GhosttySurfaceView`
/// gates `keyDown`/`insertText`/`requestWindowFirstResponder` on exactly
/// this decision -- the type itself is the honest, pure seam this can pin
/// without any real `NSView`/`NSEvent`.
final class InputSinkDispositionTests: XCTestCase {
    func testUnfocusedPaneInputSinkReceivesNothing() {
        XCTAssertEqual(InputSinkDisposition.decide(wantsFocus: false), .drop)
    }

    func testFocusedPaneInputSinkDelivers() {
        XCTAssertEqual(InputSinkDisposition.decide(wantsFocus: true), .deliver)
    }
}
