import XCTest
@testable import FlockCore

final class PaneLoaderPolicyTests: XCTestCase {
    private let shownAt = ContinuousClock.now

    func testFirstFrameBeforeMinimumHoldsToTheFloor() {
        let firstFrameAt = shownAt.advanced(by: .milliseconds(80))

        let dismissAt = PaneLoaderPolicy.dismissAt(shownAt: shownAt, firstFrameAt: firstFrameAt)

        XCTAssertEqual(dismissAt, shownAt.advanced(by: .milliseconds(2000)))
    }

    func testFirstFrameAfterMinimumDismissesImmediatelyWithNoAddedDelay() {
        let firstFrameAt = shownAt.advanced(by: .milliseconds(5000))

        let dismissAt = PaneLoaderPolicy.dismissAt(shownAt: shownAt, firstFrameAt: firstFrameAt)

        XCTAssertEqual(dismissAt, firstFrameAt)
    }

    func testFirstFrameExactlyAtTheMinimumDismissesAtThatInstant() {
        let firstFrameAt = shownAt.advanced(by: .milliseconds(2000))

        let dismissAt = PaneLoaderPolicy.dismissAt(shownAt: shownAt, firstFrameAt: firstFrameAt)

        XCTAssertEqual(dismissAt, firstFrameAt)
    }

    func testACustomMinimumIsHonoredJustLikeTheDefault() {
        let firstFrameAt = shownAt.advanced(by: .milliseconds(10))

        let dismissAt = PaneLoaderPolicy.dismissAt(shownAt: shownAt, firstFrameAt: firstFrameAt, minimum: .milliseconds(500))

        XCTAssertEqual(dismissAt, shownAt.advanced(by: .milliseconds(500)))
    }
}
