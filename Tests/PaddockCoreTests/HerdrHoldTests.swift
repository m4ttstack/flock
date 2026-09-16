import XCTest
@testable import PaddockCore

/// The hold decision: when paddock hands its panes back to herdr and when it
/// takes them again, from the app's active state alone.
final class HerdrHoldTests: XCTestCase {
    // MARK: - the release, and its debounce

    /// Paddock starts holding: a bridge takes its control client the moment it
    /// spawns, so nothing has to be done to reach the resting state.
    func testPaddockStartsHoldingWithNothingScheduled() {
        let policy = HoldPolicy()
        XCTAssertTrue(policy.isHolding)
        XCTAssertFalse(policy.isReleaseScheduled)
    }

    func testResigningActiveSchedulesTheReleaseRatherThanReleasing() {
        var policy = HoldPolicy()
        XCTAssertEqual(policy.handle(.resignedActive), .scheduleRelease(after: HoldPolicy.releaseDelay))
        XCTAssertTrue(policy.isHolding, "the panes were handed back before the delay was up")
        XCTAssertTrue(policy.isReleaseScheduled)
    }

    func testTheScheduledDeadlineIsWhatReleases() {
        var policy = HoldPolicy()
        _ = policy.handle(.resignedActive)
        XCTAssertEqual(policy.handle(.releaseDeadline), .release)
        XCTAssertFalse(policy.isHolding)
        XCTAssertFalse(policy.isReleaseScheduled)
    }

    /// The whole point of the debounce: away and back inside the delay costs
    /// herdr nothing at all, not a release followed by a take.
    func testAwayAndBackInsideTheDelayNeitherReleasesNorTakes() {
        var policy = HoldPolicy()
        XCTAssertEqual(policy.handle(.resignedActive), .scheduleRelease(after: HoldPolicy.releaseDelay))
        XCTAssertEqual(policy.handle(.becameActive), .cancelScheduledRelease)
        XCTAssertTrue(policy.isHolding)
        XCTAssertFalse(policy.isReleaseScheduled)
        // And the timer that was already in flight decides nothing when it
        // fires late.
        XCTAssertEqual(policy.handle(.releaseDeadline), .none)
        XCTAssertTrue(policy.isHolding)
    }

    func testASecondResignWhileOneIsAlreadyScheduledSchedulesNothingFurther() {
        var policy = HoldPolicy()
        _ = policy.handle(.resignedActive)
        XCTAssertEqual(policy.handle(.resignedActive), .none)
        XCTAssertTrue(policy.isReleaseScheduled)
    }

    func testResigningWhileAlreadyReleasedSchedulesNothing() {
        var policy = HoldPolicy()
        _ = policy.handle(.resignedActive)
        _ = policy.handle(.releaseDeadline)
        XCTAssertEqual(policy.handle(.resignedActive), .none)
        XCTAssertFalse(policy.isHolding)
        XCTAssertFalse(policy.isReleaseScheduled)
    }

    // MARK: - the take

    /// Not debounced, and deliberately: the user is looking at paddock by the
    /// time this runs, and a pane that is neither sized nor streaming is
    /// visible for exactly as long as the take is put off.
    func testBecomingActiveAfterAReleaseTakesThePanesBackAtOnce() {
        var policy = HoldPolicy()
        _ = policy.handle(.resignedActive)
        _ = policy.handle(.releaseDeadline)
        XCTAssertEqual(policy.handle(.becameActive), .take)
        XCTAssertTrue(policy.isHolding)
    }

    func testBecomingActiveWhileAlreadyHoldingTakesNothing() {
        var policy = HoldPolicy()
        XCTAssertEqual(policy.handle(.becameActive), .none)
        XCTAssertTrue(policy.isHolding)
    }

    /// A full round trip, and then a second one, so the machine is not a
    /// one-shot: every edge still decides the same way the second time.
    func testTwoFullRoundTripsDecideTheSameWayBothTimes() {
        var policy = HoldPolicy()
        for _ in 0..<2 {
            XCTAssertEqual(policy.handle(.resignedActive), .scheduleRelease(after: HoldPolicy.releaseDelay))
            XCTAssertEqual(policy.handle(.releaseDeadline), .release)
            XCTAssertEqual(policy.handle(.becameActive), .take)
        }
    }

    /// The delay is a real wait, and long enough to outlast the work a
    /// needless round trip would cause (twelve panes measured 204ms from the
    /// take to their last full frame).
    func testTheReleaseDelayOutlastsTheRoundTripItExistsToPrevent() {
        XCTAssertGreaterThan(HoldPolicy.releaseDelay, 0.204)
        XCTAssertLessThanOrEqual(HoldPolicy.releaseDelay, 1.0, "a switch to the terminal waits this long to be sized")
    }

    // MARK: - the wire

    /// The commands are `paddock.`-namespaced, which is what keeps them off
    /// herdr's wire: the bridge forwards every `terminal.*` line verbatim.
    func testHoldCommandsAreNamespacedSoTheyAreNeverForwardedToHerdr() throws {
        for command in HoldCommand.allCases {
            XCTAssertTrue(command.rawValue.hasPrefix("paddock."), command.rawValue)
            XCTAssertEqual(command.json["type"] as? String, command.rawValue)
            let line = try XCTUnwrap(JSONSerialization.data(withJSONObject: command.json))
            XCTAssertNil(
                ControlBridge.parseForwardableControlCommand(line),
                "\(command.rawValue) would have been sent to herdr"
            )
        }
    }

    func testParseHoldCommandReadsBothCommandsAndNothingElse() throws {
        func parse(_ json: String) -> HoldCommand? {
            ControlBridge.parseHoldCommand(Data(json.utf8))
        }
        XCTAssertEqual(parse(#"{"type":"paddock.release_hold"}"#), .release)
        XCTAssertEqual(parse(#"{"type":"paddock.take_hold"}"#), .take)
        XCTAssertNil(parse(#"{"type":"terminal.input","text":"x"}"#))
        XCTAssertNil(parse(#"{"type":"paddock.first_frame"}"#))
        XCTAssertNil(parse(#"{"type":42}"#))
        XCTAssertNil(parse("not json"))
        XCTAssertNil(parse(""))
    }

    // MARK: - the bridge's reading of a child exit

    /// The one thing that makes a release survivable: a child that exits
    /// because paddock asked it to is not the pane dying.
    func testAChildExitEndsTheBridgeOnlyWhilePaddockHolds() {
        var state = BridgeHoldState()
        XCTAssertTrue(state.isHolding)
        XCTAssertTrue(state.childExitEndsTheBridge)
        XCTAssertTrue(state.release())
        XCTAssertFalse(state.childExitEndsTheBridge, "the release would have killed the bridge")
        XCTAssertTrue(state.take())
        XCTAssertTrue(state.childExitEndsTheBridge)
    }

    /// Repeats decide nothing, so a duplicated command cannot leave two
    /// children racing for one pane or none holding it.
    func testRepeatedHoldCommandsDecideNothing() {
        var state = BridgeHoldState()
        XCTAssertFalse(state.take(), "took a pane it already held")
        XCTAssertTrue(state.release())
        XCTAssertFalse(state.release(), "released a pane it had already let go")
        XCTAssertTrue(state.take())
        XCTAssertFalse(state.take())
    }
}
