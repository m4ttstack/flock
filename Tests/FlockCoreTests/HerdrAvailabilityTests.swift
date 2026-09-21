import XCTest
@testable import FlockCore

/// The pure half of "flock has nothing to show without herdr": whether the
/// missing-herdr screen replaces the session window. The view itself is a
/// render test in Tests/FlockChromeRender, since FlockCore has no views.
final class HerdrAvailabilityTests: XCTestCase {
    func testHerdrAbsentShowsTheMissingScreen() {
        XCTAssertTrue(HerdrAvailability.shouldShowMissingScreen(herdrBinaryFound: false))
    }

    func testHerdrPresentDoesNotShowTheMissingScreen() {
        XCTAssertFalse(HerdrAvailability.shouldShowMissingScreen(herdrBinaryFound: true))
    }
}
