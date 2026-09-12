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

    // MARK: - No option: the persistent routing toggle decides, mode is irrelevant

    func testNoOptionRoutingEnabledForwardsOnEitherMode() {
        XCTAssertEqual(
            RightClickDisposition.decide(optionHeld: false, routingEnabled: true, mode: .control), .forwardToPane)
        XCTAssertEqual(
            RightClickDisposition.decide(optionHeld: false, routingEnabled: true, mode: .observe), .forwardToPane)
    }

    func testNoOptionRoutingDisabledShowsMenuOnEitherMode() {
        XCTAssertEqual(RightClickDisposition.decide(optionHeld: false, routingEnabled: false, mode: .control), .menu)
        XCTAssertEqual(RightClickDisposition.decide(optionHeld: false, routingEnabled: false, mode: .observe), .menu)
    }
}
