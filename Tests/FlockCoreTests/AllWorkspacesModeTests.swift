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

    func testTitles() {
        XCTAssertEqual(AllWorkspacesMode.allCases.map(\.title), ["Mission control", "Arrange"])
    }
}
