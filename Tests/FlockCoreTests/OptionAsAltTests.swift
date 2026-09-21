import XCTest
@testable import FlockCore

/// libghostty's `macos-option-as-alt` defaults off, which is why flock has to
/// set it at all: the store's own default is `.left`, not libghostty's `.off`,
/// since that is what a real ghostty user coming to flock already expects.
final class OptionAsAltTests: XCTestCase {
    private let suiteName = "dev.mattstack.flock.option-as-alt-tests"

    private func makeDefaults() throws -> UserDefaults {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - The mapping

    func testEachCaseMapsToLibghosttysLiteralConfigValue() {
        XCTAssertEqual(OptionAsAlt.allCases.map(\.configValue), ["false", "true", "left", "right"])
    }

    func testEachCaseIsNamedForWhatItLetsThrough() {
        XCTAssertEqual(OptionAsAlt.allCases.map(\.displayName), ["Off", "Both", "Left Option", "Right Option"])
    }

    // MARK: - The store

    @MainActor
    func testAFreshStoreOpensAtLeftNotLibghosttysOwnOffDefault() throws {
        XCTAssertEqual(OptionAsAltStore(userDefaults: try makeDefaults()).active, .left)
    }

    @MainActor
    func testAChosenValueSurvivesTheNextLaunch() throws {
        let suite = try makeDefaults()
        OptionAsAltStore(userDefaults: suite).select(.right)
        XCTAssertEqual(OptionAsAltStore(userDefaults: suite).active, .right)
    }

    /// A value written by some other build of flock is not a reason to open
    /// at something nobody asked for.
    @MainActor
    func testAValueThisBuildDoesNotKnowOpensAtLeft() throws {
        let suite = try makeDefaults()
        suite.set("sideways", forKey: OptionAsAltStore.defaultsKey)
        XCTAssertEqual(OptionAsAltStore(userDefaults: suite).active, .left)
    }
}
