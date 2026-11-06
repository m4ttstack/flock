import XCTest
@testable import FlockCore

final class SwitchLoaderRunTests: XCTestCase {
    private typealias Timing = SwitchLoaderRun.Timing

    private let working = SwitchLoaderModel(phase: .working, title: "Switching to acme-mini", status: "Connecting to acme-mini\u{2026}", showsSwitchToDefault: false)
    private let attaching = SwitchLoaderModel(phase: .working, title: "Switching to acme-mini", status: "Attaching", showsSwitchToDefault: false)
    private let failed = SwitchLoaderModel(phase: .failed, title: "Can't reach acme-mini.", status: "ssh exited.", showsSwitchToDefault: true)
    private let done = SwitchLoaderModel(phase: .done, title: "Switching to acme-mini", status: "Attaching", showsSwitchToDefault: false)

    func testTheBreathHoldsAtFullSpreadThroughEachRest() {
        XCTAssertEqual(SwitchLoaderRun.breathClock(0), 0)
        XCTAssertEqual(SwitchLoaderRun.breathClock(Timing.breath), Timing.breath, accuracy: 1e-9)
        XCTAssertEqual(SwitchLoaderRun.breathClock(Timing.breath + Timing.rest / 2), Timing.breath, accuracy: 1e-9)
        XCTAssertEqual(SwitchLoaderRun.breathClock(Timing.period + 0.1), Timing.breath + 0.1, accuracy: 1e-9)
        XCTAssertEqual(Timing.rest, 0.4)
    }

    func testARestPointIsTheEndOfTheBreathInProgressOrNowDuringARest() {
        XCTAssertEqual(SwitchLoaderRun.restPoint(atOrAfter: 0.1), Timing.breath, accuracy: 1e-9)
        let resting = Timing.breath + 0.1
        XCTAssertEqual(SwitchLoaderRun.restPoint(atOrAfter: resting), resting, accuracy: 1e-9)
        XCTAssertEqual(SwitchLoaderRun.restPoint(atOrAfter: Timing.period + 0.2), Timing.period + Timing.breath, accuracy: 1e-9)
    }

    func testDoneFinishesAfterAtLeastOneWholeBreathAndOnARest() {
        var run = SwitchLoaderRun(id: 1, startedAt: 100, model: working)
        run.apply(done, at: 0.1)
        XCTAssertEqual(run.finishAt ?? -1, Timing.breath, accuracy: 1e-9)
        XCTAssertEqual(run.endsAt ?? -1, Timing.breath + Timing.fadeOut, accuracy: 1e-9)

        var late = SwitchLoaderRun(id: 2, startedAt: 100, model: working)
        late.apply(done, at: Timing.period + 0.3)
        XCTAssertEqual(late.finishAt ?? -1, Timing.period + Timing.breath, accuracy: 1e-9)
        XCTAssertEqual(late.frame(at: late.finishAt! + 0.1).breath, late.frame(at: late.finishAt!).breath, "held while fading")
    }

    func testTheFadeTakesTheScreenToNothing() {
        var run = SwitchLoaderRun(id: 1, startedAt: 0, model: working)
        run.apply(done, at: 0.5)
        let finish = run.finishAt!
        XCTAssertEqual(run.frame(at: finish).screenOpacity, 1, accuracy: 1e-9)
        XCTAssertEqual(run.frame(at: finish + Timing.fadeOut).screenOpacity, 0, accuracy: 1e-9)
        XCTAssertEqual(run.frame(at: finish + Timing.fadeOut).exit, 1, accuracy: 1e-9)
    }

    func testItFadesInOverTheWindow() {
        let run = SwitchLoaderRun(id: 1, startedAt: 0, model: working)
        XCTAssertEqual(run.frame(at: 0).screenOpacity, 0, accuracy: 1e-9)
        XCTAssertEqual(run.frame(at: Timing.appear).screenOpacity, 1, accuracy: 1e-9)
    }

    func testAFailureStopsTheBreathOnARestTintsTheTrackAndRevealsTheButton() {
        var run = SwitchLoaderRun(id: 1, startedAt: 0, model: working)
        run.apply(failed, at: 0.3)
        XCTAssertEqual(run.breathStop ?? -1, Timing.breath, accuracy: 1e-9)
        XCTAssertTrue(run.frame(at: 0.31).isFailed)
        XCTAssertEqual(run.frame(at: 5).breath, run.frame(at: 9).breath)
        XCTAssertEqual(run.frame(at: 5).warn, 1, accuracy: 1e-9)
        XCTAssertEqual(run.frame(at: 5).shimmerOpacity, 0, accuracy: 1e-9)
        XCTAssertEqual(run.frame(at: 5).glow, 0, accuracy: 1e-9)
        XCTAssertEqual(run.frame(at: 0.3 + Timing.revealDelay).failReveal, 0, accuracy: 1e-9)
        XCTAssertEqual(run.frame(at: 5).failReveal, 1, accuracy: 1e-9)
        XCTAssertNotNil(run.settlesAt)
    }

    func testAFailureWithoutTheButtonRevealsNothing() {
        var run = SwitchLoaderRun(id: 1, startedAt: 0, model: working)
        run.apply(SwitchLoaderModel(phase: .failed, title: "x", status: "y", showsSwitchToDefault: false), at: 0.3)
        XCTAssertEqual(run.frame(at: 5).failReveal, 0)
    }

    func testARunThatStartsFailedHoldsAtOnce() {
        let run = SwitchLoaderRun(id: 1, startedAt: 0, model: failed)
        XCTAssertEqual(run.breathStop, 0)
        XCTAssertEqual(run.frame(at: 3).breath, 0)
    }

    func testRecoveringResumesTheBreathFromARest() {
        var run = SwitchLoaderRun(id: 1, startedAt: 0, model: working)
        run.apply(failed, at: 0.3)
        run.apply(attaching, at: 4)
        XCTAssertFalse(run.frame(at: 4).isFailed)
        XCTAssertNil(run.settlesAt)
        XCTAssertEqual(run.frame(at: 4).breath, 0, accuracy: 1e-9)
        XCTAssertEqual(run.frame(at: 4.2).breath, 0.2, accuracy: 1e-9)
        XCTAssertEqual(run.frame(at: 4 + Timing.warnTint).warn, 0, accuracy: 1e-9)
    }

    func testRecoveringBeforeTheBreathStoppedKeepsItGoing() {
        var run = SwitchLoaderRun(id: 1, startedAt: 0, model: working)
        run.apply(failed, at: 0.3)
        run.apply(attaching, at: 0.5)
        XCTAssertEqual(run.frame(at: 0.6).breath, 0.6, accuracy: 1e-9)
    }

    func testChangedCopyCrossfadesAndUnchangedCopyDoesNot() {
        var run = SwitchLoaderRun(id: 1, startedAt: 0, model: working)
        XCTAssertNil(run.frame(at: 0).status.previous)
        XCTAssertEqual(run.frame(at: 0).status.mix, 1)
        run.apply(attaching, at: 1)
        let mid = run.frame(at: 1 + Timing.crossfade / 2)
        XCTAssertEqual(mid.status.previous, "Connecting to acme-mini\u{2026}")
        XCTAssertEqual(mid.status.current, "Attaching")
        XCTAssertEqual(mid.status.mix, 0.5, accuracy: 1e-9)
        XCTAssertEqual(run.frame(at: 1 + Timing.crossfade).status.mix, 1, accuracy: 1e-9)
        XCTAssertNil(mid.title.previous, "the title did not change")
    }

    func testAFinishingRunKeepsItsCopy() {
        var run = SwitchLoaderRun(id: 1, startedAt: 0, model: attaching)
        run.apply(done, at: 0.5)
        run.apply(failed, at: 0.6)
        XCTAssertEqual(run.frame(at: 0.7).title.current, "Switching to acme-mini")
        XCTAssertFalse(run.frame(at: 0.7).isFailed)
    }

    func testFinishingWithoutWaitingStartsTheFadeAtOnce() {
        var run = SwitchLoaderRun(id: 1, startedAt: 0, model: attaching)
        run.finish(at: 0.1, waitForBreath: false)
        XCTAssertEqual(run.finishAt, 0.1)
    }
}
