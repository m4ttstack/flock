import XCTest
@testable import FlockCore

@MainActor
final class OverviewReturnTests: XCTestCase {
    func testTheLanesUntilChosenOtherwiseAndRemembered() {
        let name = "OverviewReturnTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(OverviewReturnStore(userDefaults: defaults).active, .lanes)
        OverviewReturnStore(userDefaults: defaults).select(.openPane)
        XCTAssertEqual(OverviewReturnStore(userDefaults: defaults).active, .openPane)
    }
}
