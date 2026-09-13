import XCTest
@testable import PaddockCore

final class RightClickDispositionTests: XCTestCase {
    // Right-clicks land in the pane by default; Option summons the herdr menu.

    // MARK: - Control mode

    func testControlModeCaptureOnPlainRightClickForwardsToPane() {
        XCTAssertEqual(
            RightClickDisposition.decide(optionHeld: false, captureEnabled: true, mode: .control),
            .forwardToPane,
            "the pane app claimed the mouse, so a plain right-click is its click")
    }

    func testControlModeCaptureOnWithOptionShowsTheMenu() {
        XCTAssertEqual(
            RightClickDisposition.decide(optionHeld: true, captureEnabled: true, mode: .control),
            .menu,
            "Option is the deliberate gesture for the herdr action menu")
    }

    func testControlModeCaptureOffShowsTheMenu() {
        XCTAssertEqual(
            RightClickDisposition.decide(optionHeld: false, captureEnabled: false, mode: .control),
            .menu,
            "nothing is listening in a plain shell, so fall through to the menu")
        XCTAssertEqual(
            RightClickDisposition.decide(optionHeld: true, captureEnabled: false, mode: .control),
            .menu)
    }

    // MARK: - Observe mode: always the menu, forwarding never happens

    func testObserveModeAlwaysShowsTheMenu() {
        for option in [false, true] {
            for capture in [false, true] {
                XCTAssertEqual(
                    RightClickDisposition.decide(optionHeld: option, captureEnabled: capture, mode: .observe),
                    .menu,
                    "the herdr menu works on any pane; an unfocused pane has no input path (option=\(option) capture=\(capture))")
            }
        }
    }
}
