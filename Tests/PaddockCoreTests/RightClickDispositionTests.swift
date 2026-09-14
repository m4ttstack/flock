import XCTest
@testable import PaddockCore

/// Right-clicks land in the pane by default; Option summons the herdr menu.
/// Every pane is attached, so focus never enters this decision.
final class RightClickDispositionTests: XCTestCase {
    func testCaptureOnPlainRightClickForwardsToPane() {
        XCTAssertEqual(
            RightClickDisposition.decide(optionHeld: false, captureEnabled: true),
            .forwardToPane,
            "the pane app claimed the mouse, so a plain right-click is its click")
    }

    func testCaptureOnWithOptionShowsTheMenu() {
        XCTAssertEqual(
            RightClickDisposition.decide(optionHeld: true, captureEnabled: true),
            .menu,
            "Option is the deliberate gesture for the herdr action menu")
    }

    func testCaptureOffShowsTheMenu() {
        XCTAssertEqual(
            RightClickDisposition.decide(optionHeld: false, captureEnabled: false),
            .menu,
            "nothing is listening in a plain shell, so fall through to the menu")
        XCTAssertEqual(
            RightClickDisposition.decide(optionHeld: true, captureEnabled: false),
            .menu)
    }
}
