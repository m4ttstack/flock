import XCTest
@testable import FlockCore

/// The launcher's visibility rule, tested standalone: pure bookkeeping over
/// pane ids where every report carries its own timestamp, so nothing here
/// sleeps.
final class PaneLauncherRegistryTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)
    private let pane = PaneID(rawValue: "w1:p2")

    @MainActor
    private var settled: Date { start.addingTimeInterval(PaneLauncherRegistry.learningWindow) }

    /// A fresh pane: rows 1, then 3, then 4 as starship's startup warnings
    /// print, all inside the learning window, then herdr says idle.
    @MainActor
    func testAFreshPaneLearnsItsPromptAcrossTheWindowAndShowsOnceIdle() {
        let registry = PaneLauncherRegistry()
        registry.recordRows(pane, rows: 1, at: start)
        registry.recordRows(pane, rows: 3, at: start.addingTimeInterval(0.3))
        registry.recordRows(pane, rows: 4, at: start.addingTimeInterval(0.6))
        XCTAssertFalse(registry.isShowing(pane), "herdr has not been asked yet")
        XCTAssertEqual(registry.nextPollDelay(pane), .zero, "a bare screen is a candidate: ask now")

        registry.recordForegroundJob(pane, idle: true, at: start.addingTimeInterval(0.7))

        XCTAssertTrue(registry.isShowing(pane))
        XCTAssertNil(registry.nextPollDelay(pane), "an idle answer ends the asking")
        XCTAssertEqual(registry.occupiedRows(pane), 4)
    }

    @MainActor
    func testOutputAfterTheWindowHidesAndTheNextDropReArms() {
        let registry = PaneLauncherRegistry()
        registry.recordRows(pane, rows: 2, at: start)
        registry.recordForegroundJob(pane, idle: true, at: start.addingTimeInterval(0.1))
        XCTAssertTrue(registry.isShowing(pane))

        registry.recordKeystroke(pane)
        registry.recordRows(pane, rows: 9, at: settled.addingTimeInterval(1))
        XCTAssertFalse(registry.isShowing(pane))
        XCTAssertNil(registry.nextPollDelay(pane), "output on screen: not a candidate, nothing to ask")

        // `clear` typed: the drop re-arms and re-learns the prompt height.
        registry.recordKeystroke(pane)
        registry.recordRows(pane, rows: 2, at: settled.addingTimeInterval(5))
        XCTAssertEqual(registry.nextPollDelay(pane), .zero)
        registry.recordForegroundJob(pane, idle: true, at: settled.addingTimeInterval(5.1))
        XCTAssertTrue(registry.isShowing(pane), "a cleared pane at an idle prompt is offered again")
    }

    @MainActor
    func testAKeystrokeHidesAndCtrlLReArmsWithoutAScreenChange() {
        let registry = PaneLauncherRegistry()
        registry.recordRows(pane, rows: 2, at: start)
        registry.recordForegroundJob(pane, idle: true, at: start.addingTimeInterval(0.1))

        registry.recordKeystroke(pane)
        XCTAssertFalse(registry.isShowing(pane))
        XCTAssertNil(registry.nextPollDelay(pane))

        registry.recordClearKey(pane)
        XCTAssertEqual(registry.nextPollDelay(pane), .zero, "the clear key reopens the question and asks herdr again")
        registry.recordForegroundJob(pane, idle: true, at: start.addingTimeInterval(1))
        XCTAssertTrue(registry.isShowing(pane))
    }

    /// `clear` then `ls` straight away: the keystrokes close the window before
    /// `ls`'s output lands, so the output is never taken for a prompt.
    @MainActor
    func testTypingInsideTheWindowClosesItSoOutputIsNotLearnedAsPrompt() {
        let registry = PaneLauncherRegistry()
        registry.recordRows(pane, rows: 2, at: start)
        registry.recordKeystroke(pane)
        registry.recordRows(pane, rows: 9, at: settled.addingTimeInterval(1))
        // `clear` lands: a drop, a new window.
        registry.recordRows(pane, rows: 2, at: settled.addingTimeInterval(2))
        // `ls` typed inside the window, output arrives inside it too.
        registry.recordKeystroke(pane)
        registry.recordRows(pane, rows: 6, at: settled.addingTimeInterval(2.5))

        registry.recordForegroundJob(pane, idle: true, at: settled.addingTimeInterval(2.6))
        XCTAssertFalse(registry.isShowing(pane), "6 rows of ls output must not read as a prompt")
        XCTAssertNil(registry.nextPollDelay(pane))
    }

    /// Inside a window, a report above the tallest prompt anyone draws is
    /// output: it closes the window instead of teaching.
    @MainActor
    func testAReportAboveTheTallestPromptInsideTheWindowIsOutput() {
        let registry = PaneLauncherRegistry()
        registry.recordRows(pane, rows: 1, at: start)
        registry.recordRows(pane, rows: PaneLauncherRegistry.tallestPrompt + 10, at: start.addingTimeInterval(0.5))

        registry.recordForegroundJob(pane, idle: true, at: start.addingTimeInterval(0.6))
        XCTAssertFalse(registry.isShowing(pane))
        XCTAssertNil(registry.nextPollDelay(pane))
    }

    /// A pane first seen mid-life: a small first screen is taken for a bare
    /// prompt; a large one waits for a drop.
    @MainActor
    func testAPaneFirstSeenMidLifeLearnsFromASmallScreenOrWaitsForADrop() {
        let small = PaneLauncherRegistry()
        small.recordRows(pane, rows: PaneLauncherRegistry.unknownHeightCap, at: start)
        XCTAssertEqual(small.nextPollDelay(pane), .zero)
        small.recordForegroundJob(pane, idle: true, at: start.addingTimeInterval(0.1))
        XCTAssertTrue(small.isShowing(pane))

        let large = PaneLauncherRegistry()
        large.recordRows(pane, rows: PaneLauncherRegistry.unknownHeightCap + 1, at: start)
        XCTAssertNil(large.nextPollDelay(pane), "a screen above the cap is content until a clear says otherwise")
        large.recordForegroundJob(pane, idle: true, at: start.addingTimeInterval(0.1))
        XCTAssertFalse(large.isShowing(pane))

        large.recordRows(pane, rows: 2, at: start.addingTimeInterval(10))
        XCTAssertEqual(large.nextPollDelay(pane), .zero, "the drop to a small screen is a clear landing")
        large.recordForegroundJob(pane, idle: true, at: start.addingTimeInterval(10.1))
        XCTAssertTrue(large.isShowing(pane))
    }

    @MainActor
    func testBusyHidesAndSchedulesBackoffThatAScreenChangeResets() {
        let backoff: [Duration] = [.milliseconds(500), .seconds(1), .seconds(2)]
        let registry = PaneLauncherRegistry(pollBackoff: backoff)
        registry.recordRows(pane, rows: 2, at: start)

        registry.recordForegroundJob(pane, idle: false, at: start.addingTimeInterval(0.1))
        XCTAssertFalse(registry.isShowing(pane))
        XCTAssertEqual(registry.nextPollDelay(pane), .milliseconds(500))
        registry.recordForegroundJob(pane, idle: nil, at: start.addingTimeInterval(0.6))
        XCTAssertEqual(registry.nextPollDelay(pane), .seconds(1), "an unknown answer is retried like busy, never the end")
        registry.recordForegroundJob(pane, idle: false, at: start.addingTimeInterval(1.6))
        XCTAssertEqual(registry.nextPollDelay(pane), .seconds(2))
        registry.recordForegroundJob(pane, idle: false, at: start.addingTimeInterval(3.6))
        XCTAssertEqual(registry.nextPollDelay(pane), .seconds(2), "the last delay repeats")

        // The prompt repaints (still bare): ask again at once.
        registry.recordRows(pane, rows: 1, at: start.addingTimeInterval(4))
        XCTAssertEqual(registry.nextPollDelay(pane), .zero)
    }

    /// The cursor blinks and the renderer asks for a frame: the count is the
    /// same, and nothing about the pane may move.
    @MainActor
    func testAnUnchangedRowCountChangesNothing() {
        let registry = PaneLauncherRegistry()
        registry.recordRows(pane, rows: 2, at: start)
        registry.recordForegroundJob(pane, idle: true, at: start.addingTimeInterval(0.1))
        XCTAssertTrue(registry.isShowing(pane))

        for tick in 1...200 {
            registry.recordRows(pane, rows: 2, at: settled.addingTimeInterval(Double(tick) * 0.6))
        }

        XCTAssertTrue(registry.isShowing(pane))
        XCTAssertNil(registry.nextPollDelay(pane), "no screen change, so no new question for herdr")
    }

    // MARK: - a navigator command (rt cd) run from the launcher

    @MainActor
    func testKeystrokesIntoThePickerDoNotEndTheNavigation() {
        let registry = PaneLauncherRegistry()
        registry.recordRows(pane, rows: 2, at: start)
        registry.recordNavigationStarted(pane, at: start.addingTimeInterval(1))
        XCTAssertFalse(registry.isShowing(pane), "the launcher steps aside while the picker is up")
        XCTAssertNil(registry.nextPollDelay(pane), "the navigation watch owns the polling meanwhile")

        registry.recordForegroundJob(pane, idle: false, at: start.addingTimeInterval(1.3))
        registry.recordKeystroke(pane)
        registry.recordRows(pane, rows: 40, at: start.addingTimeInterval(1.5))

        XCTAssertTrue(registry.isNavigating(pane))
    }

    @MainActor
    func testAnIdlePaneBeforeThePickerHasStartedIsNotItClosing() {
        let registry = PaneLauncherRegistry()
        registry.recordNavigationStarted(pane, at: start)

        registry.recordForegroundJob(pane, idle: true, at: start.addingTimeInterval(0.3))

        XCTAssertTrue(registry.isNavigating(pane))
    }

    /// A command that fails straight away can finish between two polls. Past
    /// the ceiling, idle means done. An unreadable answer meanwhile is
    /// neither running nor idle.
    @MainActor
    func testTheNavigationEndsOnIdleAfterRunningOrAfterTheCeiling() {
        let seen = PaneLauncherRegistry()
        seen.recordNavigationStarted(pane, at: start)
        seen.recordForegroundJob(pane, idle: false, at: start.addingTimeInterval(0.3))
        seen.recordForegroundJob(pane, idle: nil, at: start.addingTimeInterval(0.6))
        XCTAssertTrue(seen.isNavigating(pane), "herdr could not say: keep polling")
        seen.recordForegroundJob(pane, idle: true, at: start.addingTimeInterval(0.9))
        XCTAssertFalse(seen.isNavigating(pane))

        let unseen = PaneLauncherRegistry()
        unseen.recordNavigationStarted(pane, at: start)
        unseen.recordForegroundJob(
            pane, idle: true, at: start.addingTimeInterval(PaneLauncherRegistry.navigationStartCeiling + 0.1)
        )
        XCTAssertFalse(unseen.isNavigating(pane))
    }

    /// The picker leaves the old prompt and the command line above a new
    /// prompt. Its end clears `typed` and opens a window; the Ctrl-L the view
    /// model then sends drops the screen, and that drop is what shows.
    @MainActor
    func testTheNavigationEndReArmsAndTheClearItTriggersShows() {
        let registry = PaneLauncherRegistry()
        registry.recordRows(pane, rows: 2, at: start)
        registry.recordNavigationStarted(pane, at: settled)
        registry.recordRows(pane, rows: 40, at: settled.addingTimeInterval(0.5))
        registry.recordForegroundJob(pane, idle: false, at: settled.addingTimeInterval(0.3))
        let closedAt = settled.addingTimeInterval(8)
        registry.recordRows(pane, rows: 4, at: closedAt)
        registry.recordForegroundJob(pane, idle: true, at: closedAt)
        XCTAssertFalse(registry.isNavigating(pane))
        XCTAssertEqual(registry.occupiedRows(pane), 4)

        registry.recordRows(pane, rows: 2, at: closedAt.addingTimeInterval(0.2))
        XCTAssertEqual(registry.nextPollDelay(pane), .zero)
        registry.recordForegroundJob(pane, idle: true, at: closedAt.addingTimeInterval(0.3))
        XCTAssertTrue(registry.isShowing(pane), "back at a bare prompt in the folder the picker chose")
    }

    /// A pane flock created measures its prompt from startup output: a
    /// banner taller than the cap is the prompt's height, not content.
    @MainActor
    func testACreatedPaneTakesStartupOutputAsItsPromptAndShowsOnceIdle() {
        let registry = PaneLauncherRegistry()
        registry.recordCreated(pane)
        registry.recordRows(pane, rows: 1, at: start)
        registry.recordRows(pane, rows: 3, at: start.addingTimeInterval(0.5))
        registry.recordRows(pane, rows: 22, at: start.addingTimeInterval(1))
        XCTAssertEqual(registry.nextPollDelay(pane), .zero, "a banner keeps the pane a candidate")

        registry.recordForegroundJob(pane, idle: true, at: start.addingTimeInterval(1.2))

        XCTAssertTrue(registry.isShowing(pane))
        XCTAssertEqual(registry.occupiedRows(pane), 22)
    }

    @MainActor
    func testAPaneMarkedCreatedAfterItsFirstReportStillLearnsIt() {
        let registry = PaneLauncherRegistry()
        registry.recordRows(pane, rows: 22, at: start)
        registry.recordCreated(pane)
        XCTAssertEqual(registry.nextPollDelay(pane), .zero)

        registry.recordForegroundJob(pane, idle: true, at: start.addingTimeInterval(0.1))

        XCTAssertTrue(registry.isShowing(pane))
        XCTAssertEqual(registry.occupiedRows(pane), 22)
    }

    @MainActor
    func testAKeystrokeEndsStartupAsTyped() {
        let registry = PaneLauncherRegistry()
        registry.recordCreated(pane)
        registry.recordRows(pane, rows: 22, at: start)
        registry.recordKeystroke(pane)
        registry.recordForegroundJob(pane, idle: true, at: start.addingTimeInterval(0.1))
        XCTAssertFalse(registry.isShowing(pane))
    }

    /// A navigator typed into a fresh pane is use: what it leaves on screen
    /// is output, not a banner.
    @MainActor
    func testANavigatorEndsStartup() {
        let registry = PaneLauncherRegistry()
        registry.recordCreated(pane)
        registry.recordRows(pane, rows: 2, at: start)
        registry.recordNavigationStarted(pane, at: start.addingTimeInterval(0.5))
        let closedAt = start.addingTimeInterval(PaneLauncherRegistry.navigationStartCeiling + 1)
        registry.recordForegroundJob(pane, idle: true, at: closedAt)
        XCTAssertFalse(registry.isNavigating(pane))

        registry.recordRows(pane, rows: 30, at: closedAt.addingTimeInterval(0.2))
        registry.recordForegroundJob(pane, idle: true, at: closedAt.addingTimeInterval(0.3))
        XCTAssertFalse(registry.isShowing(pane), "the picker's leftovers were taken for a startup banner")
    }

    @MainActor
    func testANotIdleAnswerLeavesStartupOn() {
        let registry = PaneLauncherRegistry()
        registry.recordCreated(pane)
        registry.recordRows(pane, rows: 10, at: start)
        registry.recordForegroundJob(pane, idle: false, at: start.addingTimeInterval(0.1))
        registry.recordRows(pane, rows: 22, at: start.addingTimeInterval(0.5))
        registry.recordForegroundJob(pane, idle: true, at: start.addingTimeInterval(0.6))
        XCTAssertTrue(registry.isShowing(pane))
        XCTAssertEqual(registry.occupiedRows(pane), 22)
    }

    @MainActor
    func testAfterStartupEndsLaterOutputHidesAndTheNextDropReLearns() {
        let registry = PaneLauncherRegistry()
        registry.recordCreated(pane)
        registry.recordRows(pane, rows: 22, at: start)
        registry.recordForegroundJob(pane, idle: true, at: start.addingTimeInterval(0.1))
        XCTAssertTrue(registry.isShowing(pane))

        registry.recordRows(pane, rows: 30, at: start.addingTimeInterval(10))
        XCTAssertFalse(registry.isShowing(pane), "startup is over: no longer taken as the prompt")
        XCTAssertNil(registry.nextPollDelay(pane))

        registry.recordRows(pane, rows: 2, at: start.addingTimeInterval(20))
        registry.recordForegroundJob(pane, idle: true, at: start.addingTimeInterval(20.1))
        XCTAssertTrue(registry.isShowing(pane))
        XCTAssertEqual(registry.occupiedRows(pane), 2)
    }

    /// The blank between an alt-screen switch and a TUI's first paint can
    /// be read as 0 rows. It is not a prompt height: a later clear still
    /// brings the launcher back.
    @MainActor
    func testAZeroReportTeachesNothing() {
        let registry = PaneLauncherRegistry()
        registry.recordRows(pane, rows: 2, at: start)
        registry.recordForegroundJob(pane, idle: true, at: start.addingTimeInterval(0.1))
        XCTAssertTrue(registry.isShowing(pane))

        registry.recordRows(pane, rows: 0, at: settled.addingTimeInterval(1))
        registry.recordRows(pane, rows: 40, at: settled.addingTimeInterval(1.2))
        XCTAssertFalse(registry.isShowing(pane))

        registry.recordRows(pane, rows: 2, at: settled.addingTimeInterval(10))
        registry.recordForegroundJob(pane, idle: true, at: settled.addingTimeInterval(10.1))
        XCTAssertTrue(registry.isShowing(pane), "the drop back to the prompt's height is bare")
        XCTAssertEqual(registry.occupiedRows(pane), 2)
    }

    @MainActor
    func testAZeroReportInsideAWindowOrStartupTeachesNothing() {
        let windowed = PaneLauncherRegistry()
        windowed.recordRows(pane, rows: 2, at: start)
        windowed.recordRows(pane, rows: 0, at: start.addingTimeInterval(0.5))
        windowed.recordRows(pane, rows: 2, at: settled.addingTimeInterval(1))
        windowed.recordForegroundJob(pane, idle: true, at: settled.addingTimeInterval(1.1))
        XCTAssertTrue(windowed.isShowing(pane), "the prompt is still two rows")

        let created = PaneLauncherRegistry()
        created.recordCreated(pane)
        created.recordRows(pane, rows: 3, at: start)
        created.recordRows(pane, rows: 0, at: start.addingTimeInterval(0.2))
        created.recordForegroundJob(pane, idle: true, at: start.addingTimeInterval(0.3))
        created.recordRows(pane, rows: 3, at: settled.addingTimeInterval(1))
        created.recordForegroundJob(pane, idle: true, at: settled.addingTimeInterval(1.1))
        XCTAssertTrue(created.isShowing(pane), "startup learned three rows, not zero")
    }

    @MainActor
    func testForgetDropsEverythingAboutThePane() {
        let registry = PaneLauncherRegistry()
        registry.recordRows(pane, rows: 2, at: start)
        registry.recordForegroundJob(pane, idle: true, at: start)
        XCTAssertTrue(registry.isShowing(pane))

        registry.forget(pane)

        XCTAssertFalse(registry.isShowing(pane))
        XCTAssertNil(registry.nextPollDelay(pane))
        XCTAssertEqual(registry.occupiedRows(pane), 0)
    }
}
