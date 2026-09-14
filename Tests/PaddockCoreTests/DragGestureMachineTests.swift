import XCTest
@testable import PaddockCore

final class DragGestureMachineTests: XCTestCase {
    private func machine(after events: [DragGestureMachine.Event]) -> DragGestureMachine {
        var machine = DragGestureMachine()
        for event in events {
            machine.handle(event)
        }
        return machine
    }

    func testAPressStartsADrag() {
        var machine = DragGestureMachine()
        XCTAssertEqual(machine.handle(.begin), .start)
        XCTAssertEqual(machine.state, .live)
        XCTAssertTrue(machine.tracksMotion)
    }

    /// The property the two arming paths rest on: one press seen twice is one
    /// drag, and the second arm does nothing at all.
    func testASecondArmForTheSamePressDoesNothing() {
        var machine = machine(after: [.begin])
        XCTAssertEqual(machine.handle(.begin), .none)
        XCTAssertEqual(machine.state, .live)
    }

    func testEveryFurtherArmStillDoesNothing() {
        var machine = machine(after: [.begin])
        for _ in 0..<5 {
            XCTAssertEqual(machine.handle(.begin), .none)
        }
        XCTAssertEqual(machine.handle(.release), .end)
    }

    func testTheReleaseEndsTheDrag() {
        var machine = machine(after: [.begin])
        XCTAssertEqual(machine.handle(.release), .end)
        XCTAssertEqual(machine.state, .idle)
        XCTAssertFalse(machine.tracksMotion)
    }

    func testANewPressAfterAReleaseStartsAgain() {
        var machine = machine(after: [.begin, .release])
        XCTAssertEqual(machine.handle(.begin), .start)
    }

    func testEscCancelsAndStopsTrackingMotion() {
        var machine = machine(after: [.begin])
        XCTAssertEqual(machine.handle(.cancel), .cancel)
        XCTAssertEqual(machine.state, .cancelledAwaitingRelease)
        XCTAssertFalse(machine.tracksMotion)
    }

    /// The button is still down after Esc, and both arming paths keep firing
    /// while it is: neither may start a second drag.
    func testNoNewDragUntilTheButtonComesUpAfterEsc() {
        var machine = machine(after: [.begin, .cancel])
        XCTAssertEqual(machine.handle(.begin), .none)
        XCTAssertEqual(machine.state, .cancelledAwaitingRelease)
        XCTAssertEqual(machine.handle(.release), .none)
        XCTAssertEqual(machine.state, .idle)
        XCTAssertEqual(machine.handle(.begin), .start)
    }

    func testASecondEscChangesNothing() {
        var machine = machine(after: [.begin, .cancel])
        XCTAssertEqual(machine.handle(.cancel), .none)
        XCTAssertEqual(machine.state, .cancelledAwaitingRelease)
    }

    /// The release that never arrives: the drag is torn down without a commit
    /// and the gesture is over, not left waiting.
    func testAbandonEndsALiveDragWithoutCommitting() {
        var machine = machine(after: [.begin])
        XCTAssertEqual(machine.handle(.abandon), .cancel)
        XCTAssertEqual(machine.state, .idle)
    }

    func testAbandonAfterEscJustReturnsToIdle() {
        var machine = machine(after: [.begin, .cancel])
        XCTAssertEqual(machine.handle(.abandon), .none)
        XCTAssertEqual(machine.state, .idle)
    }

    func testEventsWithNoDragRunningAreAllInert() {
        for event in [DragGestureMachine.Event.cancel, .release, .abandon] {
            var machine = DragGestureMachine()
            XCTAssertEqual(machine.handle(event), .none, "\(event)")
            XCTAssertEqual(machine.state, .idle, "\(event)")
        }
    }
}
