import XCTest
@testable import FlockCore

@MainActor
final class DormantCutoffTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "DormantCutoffTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testThirtyMinutesUntilChosenOtherwise() {
        XCTAssertEqual(DormantCutoffStore(userDefaults: defaults()).active, .thirty)
    }

    func testAChoiceSurvivesANewStore() {
        let defaults = defaults()
        DormantCutoffStore(userDefaults: defaults).select(.twoHours)
        XCTAssertEqual(DormantCutoffStore(userDefaults: defaults).active, .twoHours)
    }

    func testChoicesInMinutes() {
        XCTAssertEqual(DormantCutoff.allCases.map(\.rawValue), [15, 30, 60, 120])
        XCTAssertEqual(DormantCutoff.sixty.seconds, 3600)
        XCTAssertEqual(DormantCutoff.twoHours.displayName, "2 hours")
        XCTAssertEqual(DormantCutoff.fifteen.displayName, "15 minutes")
    }
}
