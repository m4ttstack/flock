import XCTest
@testable import FlockCore

/// The rt modal's size is chosen on the modal and kept across modals and
/// launches; a flock that was never told opens it at Medium.
final class RtModalSizeTests: XCTestCase {
    private let suiteName = "dev.mattstack.flock.rt-modal-size-tests"

    private func makeDefaults() throws -> UserDefaults {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testTheSizesRunSmallToLargeUnderTheirNames() {
        XCTAssertEqual(RtModalSize.allCases, [.small, .medium, .large])
        XCTAssertEqual(RtModalSize.allCases.map(\.displayName), ["Small", "Medium", "Large"])
    }

    @MainActor
    func testAFreshStoreOpensAtMedium() throws {
        XCTAssertEqual(RtModalSizeStore(userDefaults: try makeDefaults()).active, .medium)
    }

    @MainActor
    func testAChosenSizeSurvivesTheNextLaunch() throws {
        let suite = try makeDefaults()
        for size in [RtModalSize.small, .large] {
            let store = RtModalSizeStore(userDefaults: suite)
            store.select(size)
            XCTAssertEqual(store.active, size)
            XCTAssertEqual(RtModalSizeStore(userDefaults: suite).active, size, "\(size) was not kept")
        }
    }

    /// A size written by some other build of flock is not a reason to open
    /// at something nobody asked for.
    @MainActor
    func testASizeThisBuildDoesNotKnowOpensAtMedium() throws {
        let suite = try makeDefaults()
        suite.set("huge", forKey: RtModalSizeStore.defaultsKey)
        XCTAssertEqual(RtModalSizeStore(userDefaults: suite).active, .medium)
    }
}
