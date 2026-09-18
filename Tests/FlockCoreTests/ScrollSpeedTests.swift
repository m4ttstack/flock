import XCTest
@testable import FlockCore

/// How far a wheel gesture carries is the user's to choose, but the choice
/// they never make is not: a flock that has never been told opens scrolling
/// exactly as it always did.
final class ScrollSpeedTests: XCTestCase {
    private let suiteName = "dev.mattstack.flock.scroll-speed-tests"

    private func makeDefaults() throws -> UserDefaults {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - The ladder

    /// The step every existing user is already on, and the reason they see no
    /// change until they pick another: the wheel exactly as it arrives.
    func testNormalTakesTheWheelExactlyAsItArrives() {
        XCTAssertEqual(ScrollSpeed.normal.multiplier, 1)
    }

    /// A geometric ladder, in menu order. Each step doubles the one below it
    /// so every step is a difference the hand can feel; a ladder of small
    /// percentages would read as four settings that all do nothing.
    func testEachStepDoublesTheOneBelowIt() {
        XCTAssertEqual(ScrollSpeed.allCases.map(\.multiplier), [0.5, 1, 2, 4])
    }

    func testEachStepIsNamedForHowItFeelsRatherThanForItsFactor() {
        XCTAssertEqual(ScrollSpeed.allCases.map(\.displayName), ["Slow", "Normal", "Fast", "Fastest"])
    }

    // MARK: - The store

    @MainActor
    func testAFreshStoreOpensAtNormal() throws {
        XCTAssertEqual(ScrollSpeedStore(userDefaults: try makeDefaults()).active, .normal)
    }

    @MainActor
    func testAChosenSpeedSurvivesTheNextLaunch() throws {
        let suite = try makeDefaults()
        ScrollSpeedStore(userDefaults: suite).select(.fast)
        XCTAssertEqual(ScrollSpeedStore(userDefaults: suite).active, .fast)
    }

    /// A speed written by some other build of flock is not a reason to open
    /// at something nobody asked for.
    @MainActor
    func testASpeedThisBuildDoesNotKnowOpensAtNormal() throws {
        let suite = try makeDefaults()
        suite.set("ludicrous", forKey: ScrollSpeedStore.defaultsKey)
        XCTAssertEqual(ScrollSpeedStore(userDefaults: suite).active, .normal)
    }
}
