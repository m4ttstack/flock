import XCTest
@testable import FlockCore

/// The rail's width is the user's, within bounds the window has to honour:
/// the rail never collapses, and the canvas beside it keeps a floor no drag
/// can take away.
final class RailWidthTests: XCTestCase {
    private let suiteName = "dev.mattstack.flock.rail-width-tests"

    private func defaults() throws -> UserDefaults {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - The bounds

    func testAWidthInsideTheBoundsIsTakenAsItIs() {
        XCTAssertEqual(RailWidth.clamped(240, inWindowWidth: 1400), 240)
    }

    func testTheRailNeverCollapsesAndNeverGrowsPastItsMaximum() {
        XCTAssertEqual(RailWidth.clamped(0, inWindowWidth: 1400), RailWidth.minimum)
        XCTAssertEqual(RailWidth.clamped(-500, inWindowWidth: 1400), RailWidth.minimum)
        XCTAssertEqual(RailWidth.clamped(5000, inWindowWidth: 4000), RailWidth.maximum)
    }

    /// The canvas floor, which is what stops a drag from eating the panes.
    /// The window's own minimum is 900pt, and the rail reaches its maximum
    /// there, so the floor only ever bites on a window narrower than the one
    /// flock asks for.
    func testTheCanvasKeepsItsFloorInANarrowWindow() {
        XCTAssertEqual(RailWidth.clamped(RailWidth.maximum, inWindowWidth: 900), RailWidth.maximum)

        let narrow = RailWidth.minimumContentWidth + RailWidth.minimum + 40
        XCTAssertEqual(RailWidth.clamped(RailWidth.maximum, inWindowWidth: narrow), RailWidth.minimum + 40)
    }

    /// A window too narrow to afford both holds the rail at its minimum
    /// rather than shrinking it away: the canvas is what absorbs the
    /// shortfall, since a rail of nothing is a rail nothing can grab back.
    func testAWindowTooNarrowForBothHoldsTheRailAtItsMinimum() {
        XCTAssertEqual(RailWidth.clamped(300, inWindowWidth: 200), RailWidth.minimum)
    }

    func testAnUnknownWindowWidthClampsToTheBoundsAlone() {
        XCTAssertEqual(RailWidth.clamped(5000, inWindowWidth: nil), RailWidth.maximum)
        XCTAssertEqual(RailWidth.clamped(240, inWindowWidth: nil), 240)
    }

    // MARK: - The store

    @MainActor
    func testAFreshStoreOpensAtTheDefaultWidth() throws {
        let store = RailWidthStore(userDefaults: try defaults())

        XCTAssertEqual(store.width, RailWidth.default)
    }

    @MainActor
    func testAReleaseIsWhatPersistsAndADragAloneIsNot() throws {
        let userDefaults = try defaults()
        let store = RailWidthStore(userDefaults: userDefaults)
        store.windowResized(to: 1400)

        store.dragged(to: 260)
        XCTAssertEqual(store.width, 260, "the rail did not follow the pointer")
        XCTAssertEqual(
            RailWidthStore(userDefaults: userDefaults).width, RailWidth.default,
            "a drag in flight was written down before the button came up"
        )

        store.released(at: 280)
        XCTAssertEqual(store.width, 280)
        XCTAssertEqual(RailWidthStore(userDefaults: userDefaults).width, 280, "the release was not remembered")
    }

    @MainActor
    func testAnAbandonedDragLeavesTheWidthWhereItWas() throws {
        let store = RailWidthStore(userDefaults: try defaults())
        store.windowResized(to: 1400)
        store.released(at: 250)

        store.dragged(to: 340)
        store.cancelDrag()

        XCTAssertEqual(store.width, 250)
    }

    /// A window narrower than the remembered width shrinks the rail on
    /// screen and leaves the remembered width alone, so widening the window
    /// gives back what the user asked for rather than the compromise.
    @MainActor
    func testANarrowWindowShrinksTheRailWithoutRewritingWhatWasAskedFor() throws {
        let userDefaults = try defaults()
        let store = RailWidthStore(userDefaults: userDefaults)
        store.windowResized(to: 1400)
        store.released(at: RailWidth.maximum)

        store.windowResized(to: RailWidth.minimumContentWidth + RailWidth.minimum + 20)
        XCTAssertEqual(store.width, RailWidth.minimum + 20)

        store.windowResized(to: 1400)
        XCTAssertEqual(store.width, RailWidth.maximum)
        XCTAssertEqual(RailWidthStore(userDefaults: userDefaults).width, RailWidth.maximum)
    }

    @MainActor
    func testAStoredWidthOutsideTheBoundsIsBroughtBackInside() throws {
        let userDefaults = try defaults()
        userDefaults.set(Double(9000), forKey: RailWidthStore.defaultsKey)

        XCTAssertEqual(RailWidthStore(userDefaults: userDefaults).width, RailWidth.maximum)
    }
}
