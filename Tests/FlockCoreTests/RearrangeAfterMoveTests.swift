import XCTest
@testable import FlockCore

final class RearrangeAfterMoveTests: XCTestCase {
    private let suiteName = "dev.mattstack.flock.rearrange-after-move-tests"

    private func makeDefaults() throws -> UserDefaults {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    @MainActor
    func testAFreshStoreLeavesTheModeAfterAMove() throws {
        XCTAssertEqual(RearrangeAfterMoveStore(userDefaults: try makeDefaults()).active, .leave)
    }

    @MainActor
    func testAChosenValueSurvivesTheNextLaunch() throws {
        let suite = try makeDefaults()
        RearrangeAfterMoveStore(userDefaults: suite).select(.stay)
        XCTAssertEqual(RearrangeAfterMoveStore(userDefaults: suite).active, .stay)
    }

    @MainActor
    func testAValueThisBuildDoesNotKnowOpensAtLeave() throws {
        let suite = try makeDefaults()
        suite.set("sideways", forKey: RearrangeAfterMoveStore.defaultsKey)
        XCTAssertEqual(RearrangeAfterMoveStore(userDefaults: suite).active, .leave)
    }
}
