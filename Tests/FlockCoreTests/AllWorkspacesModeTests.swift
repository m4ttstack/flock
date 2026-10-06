import XCTest
@testable import FlockCore

@MainActor
final class AllWorkspacesModeTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "AllWorkspacesModeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testMissionControlUntilChosenOtherwise() {
        XCTAssertEqual(AllWorkspacesModeStore(userDefaults: defaults()).active, .missionControl)
    }

    func testTheLastModeUsedSurvivesANewStore() {
        let defaults = defaults()
        AllWorkspacesModeStore(userDefaults: defaults).select(.arrange)
        XCTAssertEqual(AllWorkspacesModeStore(userDefaults: defaults).active, .arrange)
    }

    func testALiveDragShowsArrangeWithoutChangingTheRememberedMode() {
        let defaults = defaults()
        let store = AllWorkspacesModeStore(userDefaults: defaults)
        XCTAssertEqual(store.shown(dragInFlight: true), .arrange)
        XCTAssertEqual(store.shown(dragInFlight: false), .missionControl)
        XCTAssertEqual(AllWorkspacesModeStore(userDefaults: defaults).active, .missionControl)
    }

    func testAnOpenMidDragStaysInArrangeAfterTheDropUntilAModeIsPicked() {
        let store = AllWorkspacesModeStore(userDefaults: defaults())
        store.opened(dragInFlight: true)
        XCTAssertEqual(store.shown(dragInFlight: false), .arrange)
        store.select(.missionControl)
        XCTAssertEqual(store.shown(dragInFlight: false), .missionControl)
        store.opened(dragInFlight: true)
        store.opened(dragInFlight: false)
        XCTAssertEqual(store.shown(dragInFlight: false), .missionControl, "a later open without a drag is not held")
    }

    func testTitles() {
        XCTAssertEqual(AllWorkspacesMode.allCases.map(\.title), ["Mission control", "Arrange"])
    }
}
