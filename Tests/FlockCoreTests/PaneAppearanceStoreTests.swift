import XCTest
@testable import FlockCore

final class PaneAppearanceStoreTests: XCTestCase {
    private let suiteName = "dev.mattstack.flock.pane-appearance-tests"

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
    func testAFreshStoreOpensOnTheShippedDefaults() throws {
        let store = PaneAppearanceStore(userDefaults: try makeDefaults())
        XCTAssertEqual(store.layout, .edgeToEdge)
        XCTAssertEqual(store.focusStyle, .drainColour)
        XCTAssertEqual(store.statusLine, .aurora)
        XCTAssertEqual(store.dimness, 0.44)
        XCTAssertEqual(store.desaturation, 1.0)
    }

    @MainActor
    func testEveryChoiceSurvivesTheNextLaunch() throws {
        let suite = try makeDefaults()
        let store = PaneAppearanceStore(userDefaults: suite)
        store.select(PaneLayoutStyle.boxed)
        store.select(PaneFocusStyle.quietChrome)
        store.select(PaneStatusLineStyle.comet)
        store.setDimness(0.6)
        store.setDesaturation(0.25)

        let reopened = PaneAppearanceStore(userDefaults: suite)
        XCTAssertEqual(reopened.layout, .boxed)
        XCTAssertEqual(reopened.focusStyle, .quietChrome)
        XCTAssertEqual(reopened.statusLine, .comet)
        XCTAssertEqual(reopened.dimness, 0.6)
        XCTAssertEqual(reopened.desaturation, 0.25)
    }

    @MainActor
    func testDimnessAndDesaturationClampToTheirRanges() throws {
        let suite = try makeDefaults()
        let store = PaneAppearanceStore(userDefaults: suite)

        store.setDimness(0.05)
        XCTAssertEqual(store.dimness, PaneAppearanceStore.dimnessRange.lowerBound)
        store.setDimness(2)
        XCTAssertEqual(store.dimness, PaneAppearanceStore.dimnessRange.upperBound)
        store.setDesaturation(-1)
        XCTAssertEqual(store.desaturation, 0)
        store.setDesaturation(3)
        XCTAssertEqual(store.desaturation, 1)

        XCTAssertEqual(suite.double(forKey: PaneAppearanceStore.dimnessKey), PaneAppearanceStore.dimnessRange.upperBound)
        XCTAssertEqual(suite.double(forKey: PaneAppearanceStore.desaturationKey), 1)
    }

    /// A value written by hand or by another build is clamped on the way in.
    @MainActor
    func testOutOfRangeStoredValuesClampOnLaunch() throws {
        let suite = try makeDefaults()
        suite.set(0.0, forKey: PaneAppearanceStore.dimnessKey)
        suite.set(1.5, forKey: PaneAppearanceStore.desaturationKey)

        let store = PaneAppearanceStore(userDefaults: suite)
        XCTAssertEqual(store.dimness, PaneAppearanceStore.dimnessRange.lowerBound)
        XCTAssertEqual(store.desaturation, 1)
    }

    @MainActor
    func testUnknownStoredStylesOpenOnTheDefaults() throws {
        let suite = try makeDefaults()
        suite.set("sideways", forKey: PaneAppearanceStore.layoutKey)
        suite.set("sideways", forKey: PaneAppearanceStore.focusStyleKey)
        suite.set("sideways", forKey: PaneAppearanceStore.statusLineKey)

        let store = PaneAppearanceStore(userDefaults: suite)
        XCTAssertEqual(store.layout, PaneLayoutStyle.standard)
        XCTAssertEqual(store.focusStyle, PaneFocusStyle.standard)
        XCTAssertEqual(store.statusLine, PaneStatusLineStyle.standard)
    }

    @MainActor
    func testTheShippedDefaultsSitInsideTheirRanges() {
        XCTAssertTrue(PaneAppearanceStore.dimnessRange.contains(PaneAppearanceStore.standardDimness))
        XCTAssertTrue(PaneAppearanceStore.desaturationRange.contains(PaneAppearanceStore.standardDesaturation))
    }
}
