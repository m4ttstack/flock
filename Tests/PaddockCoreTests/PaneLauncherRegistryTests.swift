import XCTest
@testable import PaddockCore

/// The new-pane harness launcher's pristine state machine, tested standalone
/// (no herdr server needed -- it is pure bookkeeping over pane ids).
final class PaneLauncherRegistryTests: XCTestCase {
    @MainActor
    func testPristineShowsOnlyAfterPaddockCreatesThePane() {
        let registry = PaneLauncherRegistry()
        let pane = PaneID(rawValue: "w1:p2")
        XCTAssertFalse(registry.isPristine(pane), "not paddock-created yet")

        registry.registerPaddockCreated(pane)
        XCTAssertTrue(registry.isPristine(pane))
    }

    @MainActor
    func testFirstKeystrokeHidesPermanently() {
        let registry = PaneLauncherRegistry()
        let pane = PaneID(rawValue: "w1:p2")
        registry.registerPaddockCreated(pane)

        registry.recordKeystroke(pane)
        XCTAssertFalse(registry.isPristine(pane))

        // Permanent: a later "still just the prompt" screen read must not
        // resurrect it.
        registry.recordScreenActivity(pane, nonEmptyRowCount: 1)
        XCTAssertFalse(registry.isPristine(pane))
    }

    @MainActor
    func testOutputBeyondPromptHidesPermanently() {
        let registry = PaneLauncherRegistry()
        let pane = PaneID(rawValue: "w1:p2")
        registry.registerPaddockCreated(pane)

        registry.recordScreenActivity(pane, nonEmptyRowCount: 2)
        XCTAssertTrue(registry.isPristine(pane), "at most 2 non-empty rows is still just the bare prompt")

        registry.recordScreenActivity(pane, nonEmptyRowCount: 3)
        XCTAssertFalse(registry.isPristine(pane), "output beyond the prompt rows hides it for good")
    }

    @MainActor
    func testHerdrCreatedPanesNeverShow() {
        let registry = PaneLauncherRegistry()
        let pane = PaneID(rawValue: "w1:p9")
        // Never registered via `registerPaddockCreated` -- a pane herdr
        // itself created (not through paddock's split/tab/workspace verbs).
        XCTAssertFalse(registry.isPristine(pane))
        registry.recordScreenActivity(pane, nonEmptyRowCount: 1)
        XCTAssertFalse(registry.isPristine(pane))
    }
}
