import XCTest
@testable import PaddockCore

/// An injected, manually-advanced clock, the same pattern `DragControllerTests`
/// uses for `DragController`'s own dwell timer -- lets the tap/gap ceilings
/// be tested at their exact boundaries with no real waiting and no flakiness.
private final class FakeClock {
    private var instant = ContinuousClock.now

    func now() -> ContinuousClock.Instant { instant }

    func advance(by duration: Duration) {
        instant = instant.advanced(by: duration)
    }
}

/// One test per truth-table row from the task brief, plus the
/// drag-survives-key-release row it calls out by name, plus the double-tap
/// and Esc rows added afterward. The machine's own `Event` cases are
/// modifier-agnostic (`.modifierDown`/`.modifierUp`), but the currently
/// bound key is Option (`RearrangeMode`), so these names and comments
/// describe the real-world scenario each row covers.
final class RearrangeModeMachineTests: XCTestCase {
    func testStartsInactive() {
        let machine = RearrangeModeMachine()
        XCTAssertFalse(machine.active)
        XCTAssertFalse(machine.isToggled)
    }

    func testToggleOnIsActiveRegardlessOfOption() {
        for optionEvent: RearrangeModeMachine.Event? in [nil, .modifierDown] {
            var machine = RearrangeModeMachine()
            if let optionEvent { machine.handle(optionEvent) }
            machine.handle(.toggleOn)
            XCTAssertTrue(machine.active, "toggle on must be active whether or not Option is also down")
        }
    }

    func testOptionDownIsActive() {
        var machine = RearrangeModeMachine()
        machine.handle(.modifierDown)
        XCTAssertTrue(machine.active)
    }

    func testOptionUpWithNoDragInFlightIsInactiveUnlessToggled() {
        var machine = RearrangeModeMachine()
        machine.handle(.modifierDown)
        machine.handle(.modifierUp)
        XCTAssertFalse(machine.active, "Option released with nothing else holding it active must go inactive")
    }

    /// The row the brief calls out by name: a drag started under a held
    /// Option must survive the key release until the drag itself ends.
    func testDragSurvivesOptionKeyRelease() {
        var machine = RearrangeModeMachine()
        machine.handle(.modifierDown)
        machine.handle(.dragBegan)
        machine.handle(.modifierUp)
        XCTAssertTrue(machine.active, "releasing Option mid-drag must not end rearrange mode")
        machine.handle(.dragEnded)
        XCTAssertFalse(machine.active, "once the drag ends, rearrange mode re-evaluates from the current Option/toggle state")
    }

    func testDragEndingWithBothTriggersOffGoesInactive() {
        var machine = RearrangeModeMachine()
        machine.handle(.modifierDown)
        machine.handle(.dragBegan)
        machine.handle(.modifierUp)
        machine.handle(.toggleOff)
        machine.handle(.dragEnded)
        XCTAssertFalse(machine.active)
    }

    func testToggleOffWhileOptionStillHeldStaysActive() {
        var machine = RearrangeModeMachine()
        machine.handle(.modifierDown)
        machine.handle(.toggleOn)
        machine.handle(.toggleOff)
        XCTAssertTrue(machine.active, "Option is still down, so turning the sticky toggle off must not deactivate")
    }

    func testOptionDownThenToggleOnThenOptionUpStaysActive() {
        var machine = RearrangeModeMachine()
        machine.handle(.modifierDown)
        machine.handle(.toggleOn)
        machine.handle(.modifierUp)
        XCTAssertTrue(machine.active, "the sticky toggle keeps it active after Option is released")
    }

    func testIsToggledReflectsOnlyTheStickyTrigger() {
        var machine = RearrangeModeMachine()
        machine.handle(.modifierDown)
        XCTAssertFalse(machine.isToggled, "a held Option is not the sticky toggle")
        machine.handle(.toggleOn)
        XCTAssertTrue(machine.isToggled)
        machine.handle(.modifierUp)
        XCTAssertTrue(machine.isToggled, "isToggled must not be disturbed by Option's own up/down")
    }

    // MARK: - RearrangeMode's ambient sync (become/resign-key, become/resign-active)

    /// `RearrangeMode.attach` re-syncs from `NSEvent.modifierFlags` -- the
    /// ambient state, not a `.flagsChanged` edge -- whenever the window
    /// becomes key. A window that becomes key with Option already held (no
    /// down-transition ever crossed it) feeds the SAME `.modifierDown` event
    /// the machine already understands; this pins that the machine treats an
    /// ambient sync identically to a real edge.
    func testAmbientOptionHeldSyncedOnBecomeKeyActivates() {
        var machine = RearrangeModeMachine()
        XCTAssertFalse(machine.active, "nothing has happened yet")
        machine.handle(.modifierDown)
        XCTAssertTrue(machine.active, "an ambient sync reading Option down must activate, same as a real edge")
    }

    /// `RearrangeMode`'s resign-key/resign-active observers feed
    /// `.modifierForcedUp`, not a plain `.modifierUp` -- see
    /// `testForcedReleaseNeverRegistersAsATap` for why that distinction
    /// matters. With nothing else holding it active, the forced release must
    /// still deactivate.
    func testForcedOptionUpOnResignClearsAHeldOnlyActivation() {
        var machine = RearrangeModeMachine()
        machine.handle(.modifierDown)
        XCTAssertTrue(machine.active)
        machine.handle(.modifierForcedUp)
        XCTAssertFalse(machine.active, "a forced release must deactivate a held-only activation")
    }

    /// The same forced release must not disturb the sticky toggle: resigning
    /// key while the View-menu toggle is on stays active.
    func testForcedOptionUpOnResignDoesNotDisturbTheStickyToggle() {
        var machine = RearrangeModeMachine()
        machine.handle(.modifierDown)
        machine.handle(.toggleOn)
        machine.handle(.modifierForcedUp)
        XCTAssertTrue(machine.active, "the sticky toggle survives a forced resign release")
        XCTAssertTrue(machine.isToggled)
    }

    /// A resign-key/resign-active can land moments after a real Option-down,
    /// mid-press -- that press must never be misread as a short, clean tap
    /// just because it was truncated by losing observability rather than a
    /// real key-up, and it must not leave a pending tap behind either.
    func testForcedReleaseNeverRegistersAsATap() {
        let clock = FakeClock()
        var machine = RearrangeModeMachine(now: clock.now)
        machine.handle(.modifierDown)
        clock.advance(by: .milliseconds(50))
        machine.handle(.modifierForcedUp)
        XCTAssertFalse(machine.active)
        clock.advance(by: .milliseconds(50))
        machine.handle(.modifierDown)
        clock.advance(by: .milliseconds(50))
        machine.handle(.modifierUp)
        XCTAssertFalse(machine.isToggled, "a forced release must never seed a pending tap for a later real tap to complete")
    }

    // MARK: - Double-tap (sticky, timed)

    func testCleanDoubleTapTogglesStickyOn() {
        let clock = FakeClock()
        var machine = RearrangeModeMachine(now: clock.now)
        machine.handle(.modifierDown)
        clock.advance(by: .milliseconds(50))
        machine.handle(.modifierUp)
        XCTAssertFalse(machine.isToggled, "one tap alone must not toggle")
        clock.advance(by: .milliseconds(100))
        machine.handle(.modifierDown)
        clock.advance(by: .milliseconds(50))
        machine.handle(.modifierUp)
        XCTAssertTrue(machine.isToggled, "a clean double-tap must toggle sticky on")
        XCTAssertTrue(machine.active)
    }

    func testTapsTooFarApartDoNotToggle() {
        let clock = FakeClock()
        var machine = RearrangeModeMachine(now: clock.now)
        machine.handle(.modifierDown)
        clock.advance(by: .milliseconds(50))
        machine.handle(.modifierUp)
        clock.advance(by: RearrangeModeMachine.tapGapCeiling + .milliseconds(1))
        machine.handle(.modifierDown)
        clock.advance(by: .milliseconds(50))
        machine.handle(.modifierUp)
        XCTAssertFalse(machine.isToggled, "a gap over the ceiling must not complete a double-tap")
    }

    /// "One slow press (a hold) plus a tap does not [toggle]," per the
    /// ruling's own test list: a hold can never seed a pending tap, so the
    /// following clean tap only starts a fresh (incomplete) sequence.
    func testHoldThenTapDoesNotToggle() {
        let clock = FakeClock()
        var machine = RearrangeModeMachine(now: clock.now)
        machine.handle(.modifierDown)
        clock.advance(by: RearrangeModeMachine.tapCeiling + .milliseconds(1))
        machine.handle(.modifierUp)
        clock.advance(by: .milliseconds(50))
        machine.handle(.modifierDown)
        clock.advance(by: .milliseconds(50))
        machine.handle(.modifierUp)
        XCTAssertFalse(machine.isToggled, "a hold can never contribute to a double-tap")
    }

    func testOtherInputBetweenTapsCancelsTheSequence() {
        let clock = FakeClock()
        var machine = RearrangeModeMachine(now: clock.now)
        machine.handle(.modifierDown)
        clock.advance(by: .milliseconds(50))
        machine.handle(.modifierUp)
        machine.handle(.otherInputOccurred)
        clock.advance(by: .milliseconds(50))
        machine.handle(.modifierDown)
        clock.advance(by: .milliseconds(50))
        machine.handle(.modifierUp)
        XCTAssertFalse(machine.isToggled, "any other key or mouse event between the two taps cancels the sequence")
    }

    /// The rule that keeps Option-modified typing (Option held, then a
    /// letter key, in a terminal) safe: other input DURING a press, not just
    /// between two presses, disqualifies that press from ever being a tap.
    func testOtherInputDuringAPressDisqualifiesItFromEverBeingATap() {
        let clock = FakeClock()
        var machine = RearrangeModeMachine(now: clock.now)
        machine.handle(.modifierDown)
        machine.handle(.otherInputOccurred)
        clock.advance(by: .milliseconds(50))
        machine.handle(.modifierUp)
        XCTAssertFalse(machine.isToggled, "a press interrupted by other input can never be a tap, even if brief")
        clock.advance(by: .milliseconds(50))
        machine.handle(.modifierDown)
        clock.advance(by: .milliseconds(50))
        machine.handle(.modifierUp)
        XCTAssertFalse(machine.isToggled, "the interrupted press never became a pending tap, so this clean one only starts a fresh sequence")
    }

    func testHeldOptionWhileStickyOnDoesNotTurnItOffOnRelease() {
        let clock = FakeClock()
        var machine = RearrangeModeMachine(now: clock.now)
        machine.handle(.modifierDown)
        clock.advance(by: .milliseconds(50))
        machine.handle(.modifierUp)
        clock.advance(by: .milliseconds(50))
        machine.handle(.modifierDown)
        clock.advance(by: .milliseconds(50))
        machine.handle(.modifierUp)
        XCTAssertTrue(machine.isToggled, "set up: sticky is on via a clean double-tap")
        clock.advance(by: .seconds(2))
        machine.handle(.modifierDown)
        clock.advance(by: .milliseconds(800))
        machine.handle(.modifierUp)
        XCTAssertTrue(machine.active, "sticky survives an incidental hold-and-release")
        XCTAssertTrue(machine.isToggled)
    }

    // MARK: - Esc precedence

    func testEscWhenFullyInactiveDoesNothing() {
        var machine = RearrangeModeMachine()
        machine.handle(.escPressed)
        XCTAssertFalse(machine.active)
    }

    func testEscWithNoDragAndNoStickyModeDoesNothing() {
        var machine = RearrangeModeMachine()
        machine.handle(.modifierDown)
        machine.handle(.escPressed)
        XCTAssertTrue(machine.active, "esc must not touch a purely-held, non-sticky activation")
        XCTAssertFalse(machine.isToggled)
    }

    func testEscWithNoDragExitsSticky() {
        var machine = RearrangeModeMachine()
        machine.handle(.toggleOn)
        machine.handle(.escPressed)
        XCTAssertFalse(machine.active)
        XCTAssertFalse(machine.isToggled)
    }

    /// Cancelling the drag itself is the drag layer's job, reached through
    /// the same `.dragEnded` seam once it settles -- `.escPressed` alone,
    /// while a drag is in flight, must leave the sticky toggle and the held
    /// trigger exactly as they were.
    func testEscDuringADragDoesNotChangeStickyOrHeldState() {
        var machine = RearrangeModeMachine()
        machine.handle(.modifierDown)
        machine.handle(.toggleOn)
        machine.handle(.dragBegan)
        machine.handle(.escPressed)
        XCTAssertTrue(machine.isToggled, "esc during a drag must not touch the sticky toggle")
        XCTAssertTrue(machine.active)
    }

    /// The full narrative from the ruling: Esc during a sticky-mode drag
    /// takes two presses to leave the mode. The first only ends the drag
    /// (modeled as `.dragEnded`, the drag layer's own outcome, arriving
    /// after its own Esc-triggered cancellation settles); only the second,
    /// drag-free Esc actually exits sticky.
    func testEscTakesTwoPressesToLeaveStickyModeDuringADrag() {
        var machine = RearrangeModeMachine()
        machine.handle(.toggleOn)
        machine.handle(.dragBegan)
        machine.handle(.escPressed)
        machine.handle(.dragEnded)
        XCTAssertTrue(machine.active, "the first esc only cancelled the drag; sticky is still on")
        XCTAssertTrue(machine.isToggled)
        machine.handle(.escPressed)
        XCTAssertFalse(machine.active, "the second esc, with no drag in flight, exits sticky mode")
        XCTAssertFalse(machine.isToggled)
    }
}
