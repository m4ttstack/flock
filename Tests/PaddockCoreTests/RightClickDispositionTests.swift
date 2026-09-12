import XCTest
@testable import PaddockCore

final class RightClickDispositionTests: XCTestCase {
    // MARK: - Option held: always one-shot to the pane on control, drop on observe

    func testOptionHeldOnControlModeForwardsRegardlessOfRoutingToggle() {
        XCTAssertEqual(
            RightClickDisposition.decide(optionHeld: true, routingEnabled: false, mode: .control), .forwardToPane)
        XCTAssertEqual(
            RightClickDisposition.decide(optionHeld: true, routingEnabled: true, mode: .control), .forwardToPane)
    }

    func testOptionHeldOnObserveModeDropsNeverShowsMenu() {
        XCTAssertEqual(RightClickDisposition.decide(optionHeld: true, routingEnabled: false, mode: .observe), .drop)
        XCTAssertEqual(RightClickDisposition.decide(optionHeld: true, routingEnabled: true, mode: .observe), .drop)
    }

    // MARK: - No option: the persistent routing toggle asks for forwarding,
    // but it only actually reaches the pane on a control-mode surface --
    // an observe-mode pane has no input path to deliver it to, so it drops
    // rather than falling back to the menu (RULING, F6).

    func testNoOptionRoutingEnabledForwardsOnlyOnControlMode() {
        XCTAssertEqual(
            RightClickDisposition.decide(optionHeld: false, routingEnabled: true, mode: .control), .forwardToPane)
        XCTAssertEqual(
            RightClickDisposition.decide(optionHeld: false, routingEnabled: true, mode: .observe), .drop,
            "the toggle asked for forwarding; an observe-mode pane has nowhere to deliver it, so it drops, never falls back to the menu")
    }

    func testNoOptionRoutingDisabledShowsMenuOnEitherMode() {
        XCTAssertEqual(RightClickDisposition.decide(optionHeld: false, routingEnabled: false, mode: .control), .menu)
        XCTAssertEqual(RightClickDisposition.decide(optionHeld: false, routingEnabled: false, mode: .observe), .menu)
    }
}
