import XCTest
@testable import FlockCore

/// One test per row of the machine's truth table. The mode is reached by one
/// switch -- the View menu's Rearrange Mode item and its Cmd+D key equivalent
/// -- so what is left to pin is the drag override and Esc's precedence over
/// it.
final class RearrangeModeMachineTests: XCTestCase {
    func testStartsInactive() {
        let machine = RearrangeModeMachine()
        XCTAssertFalse(machine.active)
        XCTAssertFalse(machine.isToggled)
    }

    func testToggleOnActivatesAndToggleOffLeaves() {
        var machine = RearrangeModeMachine()
        machine.handle(.toggleOn)
        XCTAssertTrue(machine.active)
        XCTAssertTrue(machine.isToggled)
        machine.handle(.toggleOff)
        XCTAssertFalse(machine.active)
        XCTAssertFalse(machine.isToggled)
    }

    /// A drag begun in the mode must not end the moment the mode is turned
    /// off underneath it.
    func testDragSurvivesTheModeBeingTurnedOff() {
        var machine = RearrangeModeMachine()
        machine.handle(.toggleOn)
        machine.handle(.dragBegan)
        machine.handle(.toggleOff)
        XCTAssertTrue(machine.active, "a drag in flight holds the mode open")
        XCTAssertFalse(machine.isToggled, "the checkmark follows the switch, not the drag")
        machine.handle(.dragEnded)
        XCTAssertFalse(machine.active)
    }

    func testDragEndingWithTheToggleStillOnStaysActive() {
        var machine = RearrangeModeMachine()
        machine.handle(.toggleOn)
        machine.handle(.dragBegan)
        machine.handle(.dragEnded)
        XCTAssertTrue(machine.active)
        XCTAssertTrue(machine.isToggled)
    }

    func testEscWhenInactiveDoesNothing() {
        var machine = RearrangeModeMachine()
        machine.handle(.escPressed)
        XCTAssertFalse(machine.active)
        XCTAssertFalse(machine.isToggled)
    }

    func testEscWithNoDragLeavesTheMode() {
        var machine = RearrangeModeMachine()
        machine.handle(.toggleOn)
        machine.handle(.escPressed)
        XCTAssertFalse(machine.active)
        XCTAssertFalse(machine.isToggled)
    }

    /// Cancelling the drag itself is the drag layer's job, reached through
    /// the same `.dragEnded` seam once it settles -- `.escPressed` alone,
    /// while a drag is in flight, must leave the toggle exactly as it was.
    func testEscDuringADragDoesNotChangeTheToggle() {
        var machine = RearrangeModeMachine()
        machine.handle(.toggleOn)
        machine.handle(.dragBegan)
        machine.handle(.escPressed)
        XCTAssertTrue(machine.isToggled, "esc during a drag must not touch the toggle")
        XCTAssertTrue(machine.active)
    }

    /// Esc during a drag in the mode takes two presses to leave it. The first
    /// only ends the drag (modeled as `.dragEnded`, the drag layer's own
    /// outcome, arriving after its Esc-triggered cancellation settles); only
    /// the second, drag-free Esc actually leaves.
    func testEscTakesTwoPressesToLeaveTheModeDuringADrag() {
        var machine = RearrangeModeMachine()
        machine.handle(.toggleOn)
        machine.handle(.dragBegan)
        machine.handle(.escPressed)
        machine.handle(.dragEnded)
        XCTAssertTrue(machine.active, "the first esc only cancelled the drag; the mode is still on")
        XCTAssertTrue(machine.isToggled)
        machine.handle(.escPressed)
        XCTAssertFalse(machine.active, "the second esc, with no drag in flight, leaves the mode")
        XCTAssertFalse(machine.isToggled)
    }
}
