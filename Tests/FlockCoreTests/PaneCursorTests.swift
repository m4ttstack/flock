import XCTest
@testable import FlockCore

final class PaneCursorTests: XCTestCase {
    func testAtRestWithNoModeIsPassthrough() {
        XCTAssertEqual(PaneCursor.forPaneBody(rearrangeActive: false, paneDragInProgress: false), .passthrough)
    }

    func testRearrangeModeArmsTheWholeBodyAsOpenHand() {
        XCTAssertEqual(PaneCursor.forPaneBody(rearrangeActive: true, paneDragInProgress: false), .openHand)
    }

    func testAPaneDragInFlightIsClosedHandEvenAtRest() {
        XCTAssertEqual(PaneCursor.forPaneBody(rearrangeActive: false, paneDragInProgress: true), .closedHand)
    }

    func testAPaneDragInFlightWinsOverRearrangeModeToo() {
        XCTAssertEqual(PaneCursor.forPaneBody(rearrangeActive: true, paneDragInProgress: true), .closedHand)
    }
}
