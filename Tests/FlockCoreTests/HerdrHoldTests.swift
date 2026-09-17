import XCTest
@testable import FlockCore

/// The hold decision: when flock hands its panes back to herdr and when it
/// takes them again, from the app's active state alone.
final class HerdrHoldTests: XCTestCase {
    // MARK: - the release, and its debounce

    /// Flock starts holding: a bridge takes its control client the moment it
    /// spawns, so nothing has to be done to reach the resting state.
    func testFlockStartsHoldingWithNothingScheduled() {
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

    /// Not debounced, and deliberately: the user is looking at flock by the
    /// time this runs, and a pane that is neither sized nor streaming is
    /// visible for exactly as long as the take is put off.
    func testBecomingActiveAfterAReleaseTakesThePanesBackAtOnce() {
        var policy = HoldPolicy()
        _ = policy.handle(.resignedActive)
        _ = policy.handle(.releaseDeadline)
        XCTAssertEqual(policy.handle(.becameActive), .take)
        XCTAssertTrue(policy.isHolding)
    }

    /// Re-asserted rather than deduped: this policy's belief that it holds can
    /// be wrong in one direction (a command dropped on a full FIFO leaves that
    /// pane released with no later edge to correct it), and a bridge that
    /// already holds ignores the repeat.
    func testBecomingActiveWhileAlreadyHoldingRepeatsTheTake() {
        var policy = HoldPolicy()
        XCTAssertEqual(policy.handle(.becameActive), .take)
        XCTAssertEqual(policy.handle(.becameActive), .take)
        XCTAssertTrue(policy.isHolding)
    }

    /// The exception, and the only edge that asserts nothing: no release was
    /// ever sent, so every pane provably still holds.
    func testCancellingAScheduledReleaseAssertsNothing() {
        var policy = HoldPolicy()
        _ = policy.handle(.resignedActive)
        XCTAssertEqual(policy.handle(.becameActive), .cancelScheduledRelease)
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

    /// The status the bridge sends when it stops trying. Namespaced like the
    /// commands, and distinct from every other line the status FIFO carries,
    /// so the app's own parsers cannot confuse the three.
    func testTheHoldLostStatusIsItsOwnLineAndNoOtherParserClaimsIt() throws {
        let line = try XCTUnwrap(ControlBridge.encodeLine(["type": HoldStatus.lost.rawValue]))
        XCTAssertTrue(PaneStatusChannel.parseHoldLost(line))
        XCTAssertFalse(PaneStatusChannel.parseFirstFrame(line))
        XCTAssertNil(PaneStatusChannel.parseMouseCapture(line))
        XCTAssertNil(ControlBridge.parseHoldCommand(line), "a status read back as a command")

        let firstFrame = try XCTUnwrap(ControlBridge.encodeLine(["type": "flock.first_frame"]))
        XCTAssertFalse(PaneStatusChannel.parseHoldLost(firstFrame))
        XCTAssertFalse(PaneStatusChannel.parseHoldLost(Data("not json".utf8)))
    }

    /// The latch is monotonic within a hold, which is what keeps a resize's
    /// full frame from re-showing the card, and is cleared by exactly one
    /// thing: the bridge giving up.
    @MainActor
    func testTheFirstFrameLatchClearsOnlyWhenAHoldIsLostAndCanBeSetAgain() {
        let latch = FirstFrameLatch()
        XCTAssertFalse(latch.received)
        latch.markHoldLost()
        XCTAssertFalse(latch.received, "a pane with no frame yet gained one")
        latch.markReceived()
        latch.markReceived()
        XCTAssertTrue(latch.received)
        latch.markHoldLost()
        XCTAssertFalse(latch.received, "the card cannot come back for a dead pane")
        latch.markReceived()
        XCTAssertTrue(latch.received, "a later take could never clear the card again")
    }

    /// Pins the constant, not a behavior: the measurement it has to outlast
    /// (twelve panes, 204ms from the take to their last full frame) cannot be
    /// taken in a unit test, so the bound is asserted rather than derived.
    func testTheReleaseDelayOutlastsTheRoundTripItExistsToPrevent() {
        XCTAssertGreaterThan(HoldPolicy.releaseDelay, 0.204)
        XCTAssertLessThanOrEqual(HoldPolicy.releaseDelay, 1.0, "a switch to the terminal waits this long to be sized")
    }

    // MARK: - the wire

    /// The commands are `flock.`-namespaced, which is what keeps them off
    /// herdr's wire: the bridge forwards every `terminal.*` line verbatim.
    func testHoldCommandsAreNamespacedSoTheyAreNeverForwardedToHerdr() throws {
        for command in HoldCommand.allCases {
            XCTAssertTrue(command.rawValue.hasPrefix("flock."), command.rawValue)
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
        XCTAssertEqual(parse(#"{"type":"flock.release_hold"}"#), .release)
        XCTAssertEqual(parse(#"{"type":"flock.take_hold"}"#), .take)
        XCTAssertNil(parse(#"{"type":"terminal.input","text":"x"}"#))
        XCTAssertNil(parse(#"{"type":"flock.first_frame"}"#))
        XCTAssertNil(parse(#"{"type":42}"#))
        XCTAssertNil(parse("not json"))
        XCTAssertNil(parse(""))
    }

    // MARK: - the bridge's reading of a child exit

    /// The one thing that makes a release survivable: a child that exits
    /// because flock asked it to is not the pane dying.
    func testAChildExitIsTheExpectedReleaseOnlyWhileFlockDoesNotHold() {
        var state = BridgeHoldState()
        let old = BridgeHoldState.refusedTakeWindow + 1
        XCTAssertEqual(state.reading(fromTake: false, childAge: old), .bridgeIsFinished)
        XCTAssertTrue(state.release())
        XCTAssertEqual(
            state.reading(fromTake: true, childAge: old), .expectedRelease,
            "the release would have killed the bridge"
        )
        XCTAssertEqual(state.reading(fromTake: false, childAge: 0), .expectedRelease)
        XCTAssertTrue(state.take())
        XCTAssertEqual(state.reading(fromTake: true, childAge: old), .bridgeIsFinished)
    }

    /// herdr refuses an attach by shutting the connection down, which at the
    /// bridge looks exactly like the child exiting. Only how soon after the
    /// take tells them apart, and only for a child a take spawned: the
    /// bridge's FIRST child exiting early is a pane that could not be attached
    /// at all, which must still end the bridge as it always did.
    func testAnEarlyExitAfterATakeIsARefusalAndOneAfterTheFirstSpawnIsNot() {
        let state = BridgeHoldState()
        let early = BridgeHoldState.refusedTakeWindow / 2
        let late = BridgeHoldState.refusedTakeWindow + 0.001
        XCTAssertEqual(state.reading(fromTake: true, childAge: early), .refusedTake)
        XCTAssertEqual(state.reading(fromTake: true, childAge: late), .bridgeIsFinished)
        XCTAssertEqual(
            state.reading(fromTake: false, childAge: early), .bridgeIsFinished,
            "a first child that could not attach must still end the bridge"
        )
    }

    /// The retries are bounded, so a pane herdr will never hand back does not
    /// spawn forever; running out is what makes the app say so.
    func testTheTakeRetriesAreBoundedAndThenStop() {
        var delays: [TimeInterval] = []
        var failures = 1
        while let delay = BridgeHoldState.retryDelay(afterFailedTakes: failures) {
            delays.append(delay)
            failures += 1
            XCTAssertLessThan(failures, 10, "the retries never stop")
        }
        XCTAssertEqual(delays, BridgeHoldState.takeRetryBackoff)
        XCTAssertFalse(delays.isEmpty, "a refused take is never retried at all")
        XCTAssertEqual(delays, delays.sorted(), "the backoff does not back off")
        XCTAssertNil(BridgeHoldState.retryDelay(afterFailedTakes: 0), "a take that did not fail")
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
