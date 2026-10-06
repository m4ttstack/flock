import XCTest
@testable import FlockCore

final class JumpBackTests: XCTestCase {
    private let a = PaneID(rawValue: "a")
    private let b = PaneID(rawValue: "b")

    func testNothingToGoBackToBeforeAnyJump() {
        XCTAssertNil(JumpBack().target(livePanes: [a]))
    }

    func testAJumpRemembersWhereItLeftFrom() {
        var back = JumpBack()
        back.jumped(from: .pane(a))
        XCTAssertEqual(back.target(livePanes: [a, b]), .pane(a))
        back.jumped(from: .missionControl)
        XCTAssertEqual(back.target(livePanes: [a, b]), .missionControl)
    }

    func testGoingBackRecordsWhereItLeftSoTheNextPressGoesForward() {
        var back = JumpBack()
        back.jumped(from: .pane(a))
        back.jumped(from: .pane(b))
        XCTAssertEqual(back.target(livePanes: [a, b]), .pane(b))
    }

    func testAClosedOriginPaneOffersNothing() {
        var back = JumpBack()
        back.jumped(from: .pane(a))
        XCTAssertNil(back.target(livePanes: [b]))
    }
}
