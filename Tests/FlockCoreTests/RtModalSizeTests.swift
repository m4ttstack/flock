import XCTest
@testable import FlockCore

/// The rt modal's size is chosen on the modal, per rt command, and kept
/// across modals and launches; a flock that was never told opens it at Medium.
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
    func testAFreshStoreOpensEveryCommandAtMedium() throws {
        let store = RtModalSizeStore(userDefaults: try makeDefaults())
        for kind in RtKind.allCases {
            XCTAssertEqual(store.size(for: kind), .medium, "\(kind)")
        }
    }

    @MainActor
    func testEachCommandKeepsItsOwnSizeAcrossLaunches() throws {
        let suite = try makeDefaults()
        let store = RtModalSizeStore(userDefaults: suite)
        store.select(.small, for: .glitter)
        store.select(.large, for: .runner)

        let relaunched = RtModalSizeStore(userDefaults: suite)
        XCTAssertEqual(relaunched.size(for: .glitter), .small)
        XCTAssertEqual(relaunched.size(for: .runner), .large)
        XCTAssertEqual(relaunched.size(for: .nav), .medium, "sizing glitter moved nav")
        XCTAssertEqual(relaunched.size(for: .run), .medium, "sizing runner moved run")
    }

    /// The one size every modal shared before is where each command starts,
    /// until it is sized on its own.
    @MainActor
    func testTheSharedSizeFromBeforeSeedsEachCommand() throws {
        let suite = try makeDefaults()
        suite.set(RtModalSize.large.rawValue, forKey: RtModalSizeStore.legacyDefaultsKey)
        let store = RtModalSizeStore(userDefaults: suite)
        store.select(.small, for: .glitter)

        let relaunched = RtModalSizeStore(userDefaults: suite)
        XCTAssertEqual(relaunched.size(for: .nav), .large)
        XCTAssertEqual(relaunched.size(for: .glitter), .small)
    }

    /// A size written by some other build of flock is not a reason to open
    /// at something nobody asked for.
    @MainActor
    func testASizeThisBuildDoesNotKnowOpensAtMedium() throws {
        let suite = try makeDefaults()
        suite.set("huge", forKey: RtModalSizeStore.legacyDefaultsKey)
        suite.set("huge", forKey: RtModalSizeStore.defaultsKey(for: .nav))
        XCTAssertEqual(RtModalSizeStore(userDefaults: suite).size(for: .nav), .medium)
    }
}
