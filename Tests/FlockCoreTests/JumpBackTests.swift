import XCTest
@testable import FlockCore

final class JumpBackTests: XCTestCase {
    private let a = PaneID(rawValue: "a")
    private let b = PaneID(rawValue: "b")

    func testNothingToGoBackToBeforeAnyJump() {
        XCTAssertNil(JumpBack().target(livePanes: [a], current: nil))
    }

    func testAJumpRemembersWhereItLeftFrom() {
        var back = JumpBack()
        back.jumped(from: .pane(a), to: .pane(b))
        XCTAssertEqual(back.target(livePanes: [a, b], current: .pane(b)), .pane(a))
        back.jumped(from: .missionControl, to: .pane(b))
        XCTAssertEqual(back.target(livePanes: [a, b], current: .pane(b)), .missionControl)
    }

    func testGoingBackRecordsWhereItLeftSoTheNextPressGoesForward() {
        var back = JumpBack()
        back.jumped(from: .pane(a), to: .pane(b))
        back.jumped(from: .pane(b), to: .pane(a))
        XCTAssertEqual(back.target(livePanes: [a, b], current: .pane(a)), .pane(b))
    }

    func testAClosedOriginPaneOffersNothing() {
        var back = JumpBack()
        back.jumped(from: .pane(a), to: .pane(b))
        XCTAssertNil(back.target(livePanes: [b], current: .pane(b)))
    }

    /// Jumped A to B, then walked back to A by hand: going back to A from A
    /// would record A and leave Jump Back pointing at where you already are.
    func testNoWayBackToWhereYouAlreadyAre() {
        var back = JumpBack()
        back.jumped(from: .pane(a), to: .pane(b))
        XCTAssertNil(back.target(livePanes: [a, b], current: .pane(a)))
        var fromMission = JumpBack()
        fromMission.jumped(from: .missionControl, to: .pane(a))
        XCTAssertNil(fromMission.target(livePanes: [a], current: .missionControl))
    }

    func testAJumpThatGoesNowhereRecordsNothing() {
        var back = JumpBack()
        back.jumped(from: .missionControl, to: .pane(a))
        back.jumped(from: .pane(a), to: .pane(a))
        XCTAssertEqual(back.target(livePanes: [a, b], current: .pane(b)), .missionControl)
    }
}
