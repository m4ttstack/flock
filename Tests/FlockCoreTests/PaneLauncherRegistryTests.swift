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
    func testFirstKeystrokeHidesPermanently() {
        let registry = PaneLauncherRegistry()
        let pane = PaneID(rawValue: "w1:p2")
        registry.registerFlockCreated(pane)

        registry.recordKeystroke(pane)
        XCTAssertFalse(registry.isPristine(pane))

        // Permanent: a later screen read must not resurrect it.
        registry.recordScreenActivity(pane, nonEmptyRowCount: 1, at: start)
        registry.recordScreenActivity(pane, nonEmptyRowCount: 9, at: settled.addingTimeInterval(1))
        XCTAssertFalse(registry.isPristine(pane))
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
}
