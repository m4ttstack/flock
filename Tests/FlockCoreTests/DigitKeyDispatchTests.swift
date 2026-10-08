import XCTest
@testable import FlockCore

/// ⌘1 and on are bound once and decided at press time: into the launcher
/// when the focused pane is offering it, otherwise the views' keys.
final class DigitKeyDispatchTests: XCTestCase {
    func testADigitLaunchesWhileTheLauncherShowsAndSwitchesViewsOtherwise() {
        XCTAssertEqual(DigitKeyDispatch.decide(launcherShowing: true, index: 0), .launch(slot: 0))
        XCTAssertEqual(DigitKeyDispatch.decide(launcherShowing: true, index: 2), .launch(slot: 2))
        XCTAssertEqual(DigitKeyDispatch.decide(launcherShowing: false, index: 0), .view(index: 0))
        XCTAssertEqual(DigitKeyDispatch.decide(launcherShowing: false, index: 2), .view(index: 2))
    }

    /// Slots past the views' three digits belong to the launcher alone.
    func testDigitsPastTheViewsOnlyEverLaunch() {
        XCTAssertEqual(DigitKeyDispatch.decide(launcherShowing: true, index: 3), .launch(slot: 3))
        XCTAssertEqual(DigitKeyDispatch.decide(launcherShowing: false, index: 3), .none)
    }
}
