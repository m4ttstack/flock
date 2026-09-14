import XCTest
@testable import PaddockCore

/// One test per truth-table row from the task brief, plus the
/// drag-survives-key-release row it calls out by name.
final class RearrangeModeMachineTests: XCTestCase {
    func testStartsInactive() {
        let machine = RearrangeModeMachine()
        XCTAssertFalse(machine.active)
        XCTAssertFalse(machine.isToggled)
    }

    func testToggleOnIsActiveRegardlessOfControl() {
        for controlEvent: RearrangeModeMachine.Event? in [nil, .controlDown] {
            var machine = RearrangeModeMachine()
            if let controlEvent { machine.handle(controlEvent) }
            machine.handle(.toggleOn)
            XCTAssertTrue(machine.active, "toggle on must be active whether or not Control is also down")
        }
    }

    func testControlDownIsActive() {
        var machine = RearrangeModeMachine()
        machine.handle(.controlDown)
        XCTAssertTrue(machine.active)
    }

    func testControlUpWithNoDragInFlightIsInactiveUnlessToggled() {
        var machine = RearrangeModeMachine()
        machine.handle(.controlDown)
        machine.handle(.controlUp)
        XCTAssertFalse(machine.active, "Control released with nothing else holding it active must go inactive")
    }

    /// The row the brief calls out by name: a drag started under a held
    /// Control must survive the key release until the drag itself ends.
    func testDragSurvivesControlKeyRelease() {
        var machine = RearrangeModeMachine()
        machine.handle(.controlDown)
        machine.handle(.dragBegan)
        machine.handle(.controlUp)
        XCTAssertTrue(machine.active, "releasing Control mid-drag must not end rearrange mode")
        machine.handle(.dragEnded)
        XCTAssertFalse(machine.active, "once the drag ends, rearrange mode re-evaluates from the current Control/toggle state")
    }

    func testDragEndingWithBothTriggersOffGoesInactive() {
        var machine = RearrangeModeMachine()
        machine.handle(.controlDown)
        machine.handle(.dragBegan)
        machine.handle(.controlUp)
        machine.handle(.toggleOff)
        machine.handle(.dragEnded)
        XCTAssertFalse(machine.active)
    }

    func testToggleOffWhileControlStillHeldStaysActive() {
        var machine = RearrangeModeMachine()
        machine.handle(.controlDown)
        machine.handle(.toggleOn)
        machine.handle(.toggleOff)
        XCTAssertTrue(machine.active, "Control is still down, so turning the sticky toggle off must not deactivate")
    }

    func testControlDownThenToggleOnThenControlUpStaysActive() {
        var machine = RearrangeModeMachine()
        machine.handle(.controlDown)
        machine.handle(.toggleOn)
        machine.handle(.controlUp)
        XCTAssertTrue(machine.active, "the sticky toggle keeps it active after Control is released")
    }

    func testIsToggledReflectsOnlyTheStickyTrigger() {
        var machine = RearrangeModeMachine()
        machine.handle(.controlDown)
        XCTAssertFalse(machine.isToggled, "a held Control is not the sticky toggle")
        machine.handle(.toggleOn)
        XCTAssertTrue(machine.isToggled)
        machine.handle(.controlUp)
        XCTAssertTrue(machine.isToggled, "isToggled must not be disturbed by Control's own up/down")
    }

    // MARK: - RearrangeMode's ambient sync (become/resign-key, become/resign-active)

    /// `RearrangeMode.attach` re-syncs from `NSEvent.modifierFlags` -- the
    /// ambient state, not a `.flagsChanged` edge -- whenever the window
    /// becomes key. A window that becomes key with Control already held (no
    /// down-transition ever crossed it) feeds the SAME `.controlDown` event
    /// the machine already understands; this pins that the machine treats an
    /// ambient sync identically to a real edge.
    func testAmbientControlHeldSyncedOnBecomeKeyActivates() {
        var machine = RearrangeModeMachine()
        XCTAssertFalse(machine.active, "nothing has happened yet")
        machine.handle(.controlDown)
        XCTAssertTrue(machine.active, "an ambient sync reading Control down must activate, same as a real edge")
    }

    /// `RearrangeMode`'s resign-key/resign-active observers force
    /// `.controlUp` regardless of whether a real key-up was ever delivered to
    /// this window (it may have happened on another app entirely). With
    /// nothing else holding it active, that forced release must deactivate.
    func testForcedControlUpOnResignClearsAHeldOnlyActivation() {
        var machine = RearrangeModeMachine()
        machine.handle(.controlDown)
        XCTAssertTrue(machine.active)
        // Forced by resign-key/resign-active, not a real `.flagsChanged` up.
        machine.handle(.controlUp)
        XCTAssertFalse(machine.active, "a forced release must deactivate a held-only activation")
    }

    /// The same forced release must not disturb the sticky toggle: resigning
    /// key while the View-menu toggle is on stays active.
    func testForcedControlUpOnResignDoesNotDisturbTheStickyToggle() {
        var machine = RearrangeModeMachine()
        machine.handle(.controlDown)
        machine.handle(.toggleOn)
        machine.handle(.controlUp)
        XCTAssertTrue(machine.active, "the sticky toggle survives a forced resign release")
        XCTAssertTrue(machine.isToggled)
    }
}
