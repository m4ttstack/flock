import XCTest
@testable import FlockCore

/// The new-pane harness launcher's pristine state machine, tested standalone
/// (no herdr server needed -- it is pure bookkeeping over pane ids, and every
/// report carries its own timestamp so nothing here sleeps).
final class PaneLauncherRegistryTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    @MainActor
    private var settled: Date { start.addingTimeInterval(PaneLauncherRegistry.settleWindow) }

    @MainActor
    func testPristineShowsOnlyAfterFlockCreatesThePane() {
        let registry = PaneLauncherRegistry()
        let pane = PaneID(rawValue: "w1:p2")
        XCTAssertFalse(registry.isPristine(pane), "not flock-created yet")

        registry.registerFlockCreated(pane)
        XCTAssertTrue(registry.isPristine(pane))
    }

    @MainActor
    func testFirstKeystrokeHidesAndOrdinaryOutputNeverBringsItBack() {
        let registry = PaneLauncherRegistry()
        let pane = PaneID(rawValue: "w1:p2")
        registry.registerFlockCreated(pane)

        registry.recordKeystroke(pane)
        XCTAssertFalse(registry.isPristine(pane))

        // A clear is the only thing that reopens this. Screen reports on their
        // own, at any size, must never put the overlay back over a pane that
        // is in use.
        registry.recordScreenActivity(pane, nonEmptyRowCount: 1, at: start)
        registry.recordScreenActivity(pane, nonEmptyRowCount: 9, at: settled.addingTimeInterval(1))
        XCTAssertFalse(registry.isPristine(pane))
    }

    /// Ctrl-L at a shell prompt: the pane goes back to the screen it started
    /// with, so the offer comes back with it.
    @MainActor
    func testClearingBackToTheSettledScreenOffersTheLauncherAgain() {
        let registry = PaneLauncherRegistry()
        let pane = PaneID(rawValue: "w1:p2")
        registry.registerFlockCreated(pane)
        registry.recordScreenActivity(pane, nonEmptyRowCount: 2, at: start)
        registry.recordKeystroke(pane)
        XCTAssertFalse(registry.isPristine(pane))

        let clearedAt = settled.addingTimeInterval(30)
        registry.recordClearRequested(pane, at: clearedAt)
        registry.recordScreenActivity(pane, nonEmptyRowCount: 2, at: clearedAt.addingTimeInterval(0.3))

        XCTAssertTrue(registry.isPristine(pane), "a pane cleared back to its starting screen is offerable again")
    }

    /// Ctrl-L inside a full-screen program: the key never reaches a shell, the
    /// program repaints itself, and the overlay must stay away rather than
    /// landing on top of whatever is running.
    @MainActor
    func testAClearThatNeverEmptiesTheScreenLeavesTheLauncherHidden() {
        let registry = PaneLauncherRegistry()
        let pane = PaneID(rawValue: "w1:p2")
        registry.registerFlockCreated(pane)
        registry.recordScreenActivity(pane, nonEmptyRowCount: 2, at: start)
        registry.recordKeystroke(pane)

        let clearedAt = settled.addingTimeInterval(30)
        registry.recordClearRequested(pane, at: clearedAt)
        registry.recordScreenActivity(pane, nonEmptyRowCount: 34, at: clearedAt.addingTimeInterval(0.3))

        XCTAssertFalse(registry.isPristine(pane))
    }

    /// The watch is bounded. A screen that empties long after the key was
    /// pressed is the program doing something of its own, not that clear.
    @MainActor
    func testAScreenThatEmptiesAfterTheClearWindowIsIgnored() {
        let registry = PaneLauncherRegistry()
        let pane = PaneID(rawValue: "w1:p2")
        registry.registerFlockCreated(pane)
        registry.recordScreenActivity(pane, nonEmptyRowCount: 2, at: start)
        registry.recordKeystroke(pane)

        let clearedAt = settled.addingTimeInterval(30)
        registry.recordClearRequested(pane, at: clearedAt)
        let tooLate = clearedAt.addingTimeInterval(PaneLauncherRegistry.clearWindow + 1)
        registry.recordScreenActivity(pane, nonEmptyRowCount: 2, at: tooLate)

        XCTAssertFalse(registry.isPristine(pane))
    }

    /// Typing after the clear puts it away again, the same as any other
    /// keystroke, rather than leaving the buttons over a pane being used.
    @MainActor
    func testTypingAfterAClearHidesTheLauncherAgain() {
        let registry = PaneLauncherRegistry()
        let pane = PaneID(rawValue: "w1:p2")
        registry.registerFlockCreated(pane)
        registry.recordScreenActivity(pane, nonEmptyRowCount: 2, at: start)
        registry.recordKeystroke(pane)
        let clearedAt = settled.addingTimeInterval(30)
        registry.recordClearRequested(pane, at: clearedAt)
        registry.recordScreenActivity(pane, nonEmptyRowCount: 2, at: clearedAt.addingTimeInterval(0.3))
        XCTAssertTrue(registry.isPristine(pane))

        registry.recordKeystroke(pane)

        XCTAssertFalse(registry.isPristine(pane))
    }

    /// Clearing works on a pane flock never opened. This was provenance-gated
    /// at first, which made the feature unreliable for the wrong reason: the
    /// registry is in-memory, so restarting flock made every pane already on
    /// screen permanently ineligible and clearing one did nothing all session.
    @MainActor
    func testClearingAPaneFlockNeverCreatedStillOffersTheLauncher() {
        let registry = PaneLauncherRegistry()
        let pane = PaneID(rawValue: "w1:p2")
        XCTAssertFalse(registry.isPristine(pane), "herdr's own pane offers nothing until it is cleared")

        let clearedAt = settled.addingTimeInterval(30)
        registry.recordClearRequested(pane, at: clearedAt)
        // Its first report is the one that learns what this pane's prompt
        // looks like, since it was never watched while pristine.
        registry.recordScreenActivity(pane, nonEmptyRowCount: 2, at: clearedAt.addingTimeInterval(0.3))
        registry.recordScreenActivity(pane, nonEmptyRowCount: 2, at: clearedAt.addingTimeInterval(0.6))

        XCTAssertTrue(registry.isPristine(pane))
    }

    /// Without a clear, a pane flock never opened is still not flock's to put
    /// an overlay on, however empty its screen happens to look.
    @MainActor
    func testAPaneFlockNeverCreatedOffersNothingOnItsOwn() {
        let registry = PaneLauncherRegistry()
        let pane = PaneID(rawValue: "w1:p2")

        registry.recordScreenActivity(pane, nonEmptyRowCount: 2, at: start)
        registry.recordScreenActivity(pane, nonEmptyRowCount: 2, at: settled.addingTimeInterval(1))

        XCTAssertFalse(registry.isPristine(pane))
    }

    /// Counting a surface's rows is a full buffer scan, so it runs only while
    /// the answer can still move: while the pane is still offering, or while a
    /// clear is outstanding. Not on a pane in use, which is most of them, most
    /// of the time.
    @MainActor
    func testRowCountingRunsOnlyWhileAnAnswerCouldStillChange() {
        let registry = PaneLauncherRegistry()
        let pane = PaneID(rawValue: "w1:p2")
        registry.registerFlockCreated(pane)
        XCTAssertTrue(registry.wantsScreenActivity(pane, at: start), "still offering")

        registry.recordKeystroke(pane)
        XCTAssertFalse(registry.wantsScreenActivity(pane, at: start), "in use, and no clear asked for")

        let clearedAt = settled.addingTimeInterval(30)
        registry.recordClearRequested(pane, at: clearedAt)
        XCTAssertTrue(registry.wantsScreenActivity(pane, at: clearedAt), "a clear is outstanding")
        XCTAssertFalse(
            registry.wantsScreenActivity(pane, at: clearedAt.addingTimeInterval(PaneLauncherRegistry.clearWindow + 1)),
            "the clear window closed, so counting stops again"
        )
    }

    /// The defect this rule was rewritten for: Matt's starship prompt prints
    /// a path line, the prompt line and two `[WARN] (starship::context)`
    /// lines as the shell comes up, so the first real frame already carries
    /// four non-empty rows. None of it is use.
    @MainActor
    func testAShellWithANoisyStartupKeepsTheLauncher() {
        let registry = PaneLauncherRegistry()
        let pane = PaneID(rawValue: "w1:p2")
        registry.registerFlockCreated(pane)

        registry.recordScreenActivity(pane, nonEmptyRowCount: 1, at: start)
        registry.recordScreenActivity(pane, nonEmptyRowCount: 3, at: start.addingTimeInterval(0.25))
        registry.recordScreenActivity(pane, nonEmptyRowCount: 4, at: start.addingTimeInterval(0.5))

        XCTAssertTrue(registry.isPristine(pane), "a noisy shell startup is not the pane being used")
    }

    /// The pane's clock starts at its FIRST frame, not at the moment flock
    /// created it: a pane created in a workspace that is not on screen has no
    /// surface, and so prints nothing, until one attaches.
    @MainActor
    func testTheSettleWindowRunsFromTheFirstFrameNotFromCreation() {
        let registry = PaneLauncherRegistry()
        let pane = PaneID(rawValue: "w1:p2")
        registry.registerFlockCreated(pane)

        let lateAttach = start.addingTimeInterval(600)
        registry.recordScreenActivity(pane, nonEmptyRowCount: 1, at: lateAttach)
        registry.recordScreenActivity(pane, nonEmptyRowCount: 4, at: lateAttach.addingTimeInterval(0.5))

        XCTAssertTrue(registry.isPristine(pane), "the startup burst arrived when the surface did, ten minutes late")
    }

    @MainActor
    func testOutputAfterThePaneSettlesHidesPermanently() {
        let registry = PaneLauncherRegistry()
        let pane = PaneID(rawValue: "w1:p2")
        registry.registerFlockCreated(pane)
        registry.recordScreenActivity(pane, nonEmptyRowCount: 4, at: start)
        registry.recordScreenActivity(pane, nonEmptyRowCount: 4, at: start.addingTimeInterval(0.5))
        XCTAssertTrue(registry.isPristine(pane))

        registry.recordScreenActivity(pane, nonEmptyRowCount: 6, at: settled.addingTimeInterval(1))

        XCTAssertFalse(registry.isPristine(pane), "output the pane printed after it settled is the pane in use")
    }

    /// Output that replaces the screen rather than adding to it -- a `clear`,
    /// a full-screen program taking over -- is use just the same, so the test
    /// is a CHANGE from the settled screen, never growth past a row count.
    @MainActor
    func testOutputThatShrinksTheScreenAlsoHides() {
        let registry = PaneLauncherRegistry()
        let pane = PaneID(rawValue: "w1:p2")
        registry.registerFlockCreated(pane)
        registry.recordScreenActivity(pane, nonEmptyRowCount: 4, at: start)

        registry.recordScreenActivity(pane, nonEmptyRowCount: 1, at: settled.addingTimeInterval(1))

        XCTAssertFalse(registry.isPristine(pane))
    }

    /// A settled pane still repaints: ghostty asks for a render on a blinking
    /// cursor, and a prompt with a clock in it redraws every second. Neither
    /// changes what is on the screen, and neither is use.
    @MainActor
    func testARepaintingIdlePaneStaysPristineIndefinitely() {
        let registry = PaneLauncherRegistry()
        let pane = PaneID(rawValue: "w1:p2")
        registry.registerFlockCreated(pane)
        registry.recordScreenActivity(pane, nonEmptyRowCount: 4, at: start)

        for tick in 1...200 {
            registry.recordScreenActivity(pane, nonEmptyRowCount: 4, at: settled.addingTimeInterval(Double(tick) * 0.5))
        }

        XCTAssertTrue(registry.isPristine(pane), "repainting the same screen is not output")
    }

    @MainActor
    func testHerdrCreatedPanesNeverShow() {
        let registry = PaneLauncherRegistry()
        let pane = PaneID(rawValue: "w1:p9")
        // Never registered via `registerFlockCreated` -- a pane herdr
        // itself created (not through flock's split/tab/workspace verbs).
        XCTAssertFalse(registry.isPristine(pane))
        registry.recordScreenActivity(pane, nonEmptyRowCount: 1, at: start)
        XCTAssertFalse(registry.isPristine(pane))
    }

    // MARK: - a navigator command (rt cd) run from the launcher

    /// The picker takes keys for as long as it is open. Those keys are the
    /// navigator being used, not the pane, so none of them may end it.
    @MainActor
    func testKeystrokesIntoThePickerDoNotEndTheNavigation() {
        let registry = PaneLauncherRegistry()
        let pane = PaneID(rawValue: "w1:p2")
        registry.registerFlockCreated(pane)

        registry.recordNavigationStarted(pane, at: start)
        XCTAssertFalse(registry.isPristine(pane), "the launcher steps aside while the picker is up")
        registry.recordForegroundJob(pane, busy: true, at: start.addingTimeInterval(0.3))
        registry.recordKeystroke(pane)
        registry.recordKeystroke(pane)

        XCTAssertTrue(registry.isNavigating(pane))
    }

    @MainActor
    func testThePickerClosingOffersTheLauncherAgain() {
        let registry = PaneLauncherRegistry()
        let pane = PaneID(rawValue: "w1:p2")
        registry.registerFlockCreated(pane)
        registry.recordNavigationStarted(pane, at: start)
        registry.recordForegroundJob(pane, busy: true, at: start.addingTimeInterval(0.3))
        registry.recordKeystroke(pane)

        registry.recordForegroundJob(pane, busy: false, at: start.addingTimeInterval(5))

        XCTAssertFalse(registry.isNavigating(pane))
        XCTAssertTrue(registry.isPristine(pane), "back at a prompt, in the folder the picker chose")
    }

    /// The first poll can land before the shell has even started the command,
    /// when the pane is still sitting at the prompt the click typed into.
    @MainActor
    func testAnIdlePaneBeforeThePickerHasStartedIsNotItClosing() {
        let registry = PaneLauncherRegistry()
        let pane = PaneID(rawValue: "w1:p2")
        registry.registerFlockCreated(pane)
        registry.recordNavigationStarted(pane, at: start)

        registry.recordForegroundJob(pane, busy: false, at: start.addingTimeInterval(0.3))

        XCTAssertTrue(registry.isNavigating(pane))
        XCTAssertFalse(registry.isPristine(pane))
    }

    /// A command that fails straight away may finish between two polls and
    /// never be seen running. Past the ceiling, an idle pane is taken as done.
    @MainActor
    func testACommandNeverSeenRunningHandsTheLauncherBackAfterTheCeiling() {
        let registry = PaneLauncherRegistry()
        let pane = PaneID(rawValue: "w1:p2")
        registry.registerFlockCreated(pane)
        registry.recordNavigationStarted(pane, at: start)

        registry.recordForegroundJob(
            pane, busy: false, at: start.addingTimeInterval(PaneLauncherRegistry.navigationStartCeiling + 0.1)
        )

        XCTAssertFalse(registry.isNavigating(pane))
        XCTAssertTrue(registry.isPristine(pane))
    }

    /// The picker paints the whole pane, so nothing it draws may count, and
    /// the prompt it leaves behind sits lower than the one the pane settled
    /// at: that new screen is what later output is measured against.
    @MainActor
    func testTheScreenAfterANavigationBecomesTheNewSettledScreen() {
        let registry = PaneLauncherRegistry()
        let pane = PaneID(rawValue: "w1:p2")
        registry.registerFlockCreated(pane)
        registry.recordScreenActivity(pane, nonEmptyRowCount: 2, at: start)
        let startedAt = settled.addingTimeInterval(10)
        registry.recordNavigationStarted(pane, at: startedAt)
        XCTAssertFalse(registry.wantsScreenActivity(pane, at: startedAt), "the picker's own frames are not worth counting")
        registry.recordScreenActivity(pane, nonEmptyRowCount: 30, at: startedAt.addingTimeInterval(0.5))
        registry.recordForegroundJob(pane, busy: true, at: startedAt.addingTimeInterval(0.3))
        let closedAt = startedAt.addingTimeInterval(8)
        registry.recordForegroundJob(pane, busy: false, at: closedAt)
        XCTAssertTrue(registry.wantsScreenActivity(pane, at: closedAt))

        registry.recordScreenActivity(pane, nonEmptyRowCount: 4, at: closedAt.addingTimeInterval(0.3))
        registry.recordScreenActivity(pane, nonEmptyRowCount: 4, at: closedAt.addingTimeInterval(PaneLauncherRegistry.settleWindow + 1))
        XCTAssertTrue(registry.isPristine(pane), "the taller prompt the cd left behind is not output")

        registry.recordScreenActivity(pane, nonEmptyRowCount: 7, at: closedAt.addingTimeInterval(PaneLauncherRegistry.settleWindow + 2))
        XCTAssertFalse(registry.isPristine(pane))
    }

    /// A pane that closed, or a herdr that stopped answering for it, leaves
    /// nothing to hand the launcher back to; later reports are stale.
    @MainActor
    func testAForgottenNavigationLeavesTheLauncherHidden() {
        let registry = PaneLauncherRegistry()
        let pane = PaneID(rawValue: "w1:p2")
        registry.registerFlockCreated(pane)
        registry.recordNavigationStarted(pane, at: start)
        registry.recordForegroundJob(pane, busy: true, at: start.addingTimeInterval(0.3))

        registry.forgetNavigation(pane)
        registry.recordForegroundJob(pane, busy: false, at: start.addingTimeInterval(5))

        XCTAssertFalse(registry.isNavigating(pane))
        XCTAssertFalse(registry.isPristine(pane))
    }

    @MainActor
    func testForegroundReportsOnAPaneThatIsNotNavigatingChangeNothing() {
        let registry = PaneLauncherRegistry()
        let pane = PaneID(rawValue: "w1:p2")
        registry.registerFlockCreated(pane)
        registry.recordKeystroke(pane)

        registry.recordForegroundJob(pane, busy: true, at: start)
        registry.recordForegroundJob(pane, busy: false, at: start.addingTimeInterval(10))

        XCTAssertFalse(registry.isPristine(pane))
    }
}
