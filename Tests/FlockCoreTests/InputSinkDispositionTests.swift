import XCTest
@testable import FlockCore

/// An unfocused pane's input sink must receive nothing: `GhosttySurfaceView`
/// gates `keyDown`/`insertText`/`requestWindowFirstResponder` on exactly
/// this decision -- the type itself is the honest, pure seam this can pin
/// without any real `NSView`/`NSEvent`. Every pane holds a live control
/// bridge now, so this gate and AppKit's own single-first-responder rule are
/// what keep a keystroke out of a pane the user is not in.
final class InputSinkDispositionTests: XCTestCase {
    func testUnfocusedPaneInputSinkReceivesNothing() {
        XCTAssertEqual(InputSinkDisposition.decide(wantsFocus: false), .drop)
    }

    func testFocusedPaneInputSinkDelivers() {
        XCTAssertEqual(InputSinkDisposition.decide(wantsFocus: true), .deliver)
    }
}
