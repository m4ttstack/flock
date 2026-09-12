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
    }

    @MainActor
    func testHerdrCreatedPanesNeverShow() {
        let registry = PaneLauncherRegistry()
        let pane = PaneID(rawValue: "w1:p9")
        // Never registered via `registerPaddockCreated` -- a pane herdr
        // itself created (not through paddock's split/tab/workspace verbs).
        XCTAssertFalse(registry.isPristine(pane))
        registry.recordKeystroke(pane)
        XCTAssertFalse(registry.isPristine(pane))
    }
}
