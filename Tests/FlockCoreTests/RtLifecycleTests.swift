import XCTest
@testable import FlockCore

final class RtLifecycleTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)
    private let resultLine = #"{"targetDir":"/src/acme/web","packageLabel":"web","worktree":"/src/acme","branch":"main","commandTemplate":"pnpm run test","script":"test"}"#

    private func seen(busy: Bool, first: Bool? = nil, status: Int32? = nil, statusExists: Bool = false, out: String? = nil, at seconds: TimeInterval) -> RtLifecycle.Observation {
        RtLifecycle.Observation(
            firstPaneBusy: first ?? busy, anyPaneBusy: busy, statusExists: statusExists || status != nil,
            status: status, out: out, now: start.addingTimeInterval(seconds)
        )
    }

    func testNavQuittingCleanlyClosesItsTab() {
        var life = RtLifecycle(kind: .nav, startedAt: start)
        XCTAssertEqual(life.observe(seen(busy: true, at: 0.3)), .watching)
        XCTAssertEqual(life.observe(seen(busy: false, status: 0, out: "", at: 5)), .closeTab)
        XCTAssertEqual(life.stage, .done)
    }

    func testNavCdHereCarriesTheFolder() {
        var life = RtLifecycle(kind: .nav, startedAt: start)
        _ = life.observe(seen(busy: true, at: 0.3))
        XCTAssertEqual(life.observe(seen(busy: false, status: 0, out: "/src/acme/web\n", at: 5)), .cdLinkedPane("/src/acme/web"))
    }

    func testCancelledIsClean() {
        var life = RtLifecycle(kind: .glitter, startedAt: start)
        _ = life.observe(seen(busy: true, at: 0.3))
        XCTAssertEqual(life.observe(seen(busy: false, status: 130, at: 5)), .closeTab)
    }

    func testAnUncleanExitShowsItsStatus() {
        var life = RtLifecycle(kind: .glitter, startedAt: start)
        _ = life.observe(seen(busy: true, at: 0.3))
        XCTAssertEqual(life.observe(seen(busy: false, status: 1, at: 5)), .exited(1))
    }

    /// rt exits before the shell writes the status; the gap is not the end.
    func testIdleWithoutAStatusAfterRunningIsStillWatching() {
        var life = RtLifecycle(kind: .nav, startedAt: start)
        _ = life.observe(seen(busy: true, at: 0.3))
        XCTAssertEqual(life.observe(seen(busy: false, at: 5)), .watching)
    }

    func testACommandNeverSeenRunningEndsAtTheCeilingAsUnclean() {
        var life = RtLifecycle(kind: .glitter, startedAt: start)
        XCTAssertEqual(life.observe(seen(busy: false, at: 1)), .watching)
        XCTAssertEqual(life.observe(seen(busy: false, at: RtLifecycle.startCeiling + 0.1)), .exited(nil))
    }

    func testAFastCommandWithAStatusEndsWithoutEverBeingSeen() {
        var life = RtLifecycle(kind: .glitter, startedAt: start)
        XCTAssertEqual(life.observe(seen(busy: false, status: 1, at: 0.3)), .exited(1))
    }

    func testTheRunnerQuittingEndsIt() {
        var life = RtLifecycle(kind: .runner, startedAt: start)
        _ = life.observe(seen(busy: true, at: 0.3))
        XCTAssertEqual(life.observe(seen(busy: false, status: 0, at: 60)), .runnerEnded)
    }

    func testRunPhaseOneWithAResultAsksForPhaseTwo() {
        var life = RtLifecycle(kind: .run, startedAt: start)
        XCTAssertEqual(life.stage, .picking)
        _ = life.observe(seen(busy: true, at: 0.3))
        let outcome = life.observe(seen(busy: false, status: 0, out: resultLine, at: 4))
        XCTAssertEqual(outcome, .typePhaseTwo(RtFileParse.runResult(resultLine)!))

        life.phaseTwoTyped(at: start.addingTimeInterval(4.1))
        XCTAssertEqual(life.stage, .script)
        XCTAssertEqual(life.observe(seen(busy: true, at: 4.4)), .watching)
        XCTAssertEqual(life.observe(seen(busy: false, status: 2, at: 9)), .finished(2))
    }

    /// Phase 1 ends on the first pane only; a split "Launch all" made is still busy.
    func testPhaseOneEndsOnTheFirstPaneAlone() {
        var life = RtLifecycle(kind: .run, startedAt: start)
        _ = life.observe(seen(busy: true, at: 0.3))
        XCTAssertEqual(life.observe(seen(busy: true, first: false, status: 0, at: 4)), .watching)
        XCTAssertEqual(life.stage, .selfLaunched)
    }

    func testASelfLaunchFinishesWithoutAStatusOnceItsPanesGoQuiet() {
        var life = RtLifecycle(kind: .run, startedAt: start)
        _ = life.observe(seen(busy: true, at: 0.3))
        _ = life.observe(seen(busy: false, status: 0, at: 4))
        XCTAssertEqual(life.stage, .selfLaunched)
        XCTAssertEqual(life.observe(seen(busy: false, status: 0, at: 4.3)), .watching, "the script rt typed has not started yet")
        XCTAssertEqual(life.observe(seen(busy: true, at: 4.6)), .watching)
        XCTAssertEqual(life.observe(seen(busy: false, status: 0, at: 30)), .finished(nil))
    }

    func testASelfLaunchNeverSeenRunningFinishesAtTheCeiling() {
        var life = RtLifecycle(kind: .run, startedAt: start)
        _ = life.observe(seen(busy: true, at: 0.3))
        _ = life.observe(seen(busy: false, status: 0, at: 4))
        XCTAssertEqual(life.observe(seen(busy: false, status: 0, at: 4 + RtLifecycle.startCeiling + 0.1)), .finished(nil))
    }

    func testRunPhaseOneWithNoResultAndAFailureIsACancel() {
        var life = RtLifecycle(kind: .run, startedAt: start)
        _ = life.observe(seen(busy: true, at: 0.3))
        XCTAssertEqual(life.observe(seen(busy: false, status: 1, at: 4)), .closeTab)
    }

    func testAResumedItemCarriesOnFromItsStage() {
        var life = RtLifecycle.resumed(kind: .run, stage: .script, at: start)
        XCTAssertEqual(life.observe(seen(busy: false, status: 0, at: 0.3)), .finished(0))
    }

    /// ctrl+c on the script: the shell skips the status write.
    func testAScriptStoppedWithoutAStatusFinishesAfterTheGrace() {
        var life = RtLifecycle(kind: .run, startedAt: start)
        _ = life.observe(seen(busy: true, at: 0.3))
        _ = life.observe(seen(busy: false, status: 0, out: resultLine, at: 4))
        life.phaseTwoTyped(at: start.addingTimeInterval(4.1))
        _ = life.observe(seen(busy: true, at: 4.4))

        XCTAssertEqual(life.observe(seen(busy: false, at: 60)), .watching, "the grace starts at the first idle poll")
        XCTAssertEqual(life.observe(seen(busy: false, at: 60 + RtLifecycle.startCeiling + 0.1)), .finished(nil))
    }

    func testACommandKilledWithoutAStatusExitsAfterTheGrace() {
        var life = RtLifecycle(kind: .glitter, startedAt: start)
        _ = life.observe(seen(busy: true, at: 0.3))
        XCTAssertEqual(life.observe(seen(busy: false, at: 5)), .watching)
        XCTAssertEqual(life.observe(seen(busy: false, at: 5 + RtLifecycle.startCeiling + 0.1)), .exited(nil))
    }

    func testBusyAgainRestartsTheGrace() {
        var life = RtLifecycle(kind: .glitter, startedAt: start)
        _ = life.observe(seen(busy: true, at: 0.3))
        _ = life.observe(seen(busy: false, at: 5))
        _ = life.observe(seen(busy: true, at: 6))
        XCTAssertEqual(life.observe(seen(busy: false, at: 5 + RtLifecycle.startCeiling + 0.1)), .watching)
    }
}
