import XCTest
@testable import FlockCore

final class PaneLoaderPolicyTests: XCTestCase {
    private let shownAt = ContinuousClock.now

    /// The one place the floor's actual value is asserted, so changing it is
    /// a deliberate edit rather than a number the behaviour tests quietly
    /// follow. Every other test below reads the constant.
    func testTheFloorIsOneAndAHalfSeconds() {
        XCTAssertEqual(PaneLoaderPolicy.minimumDisplay, .milliseconds(1500))
    }

    func testFirstFrameBeforeMinimumHoldsToTheFloor() {
        let firstFrameAt = shownAt.advanced(by: .milliseconds(80))

        let dismissAt = PaneLoaderPolicy.dismissAt(shownAt: shownAt, firstFrameAt: firstFrameAt)

        XCTAssertEqual(dismissAt, shownAt.advanced(by: PaneLoaderPolicy.minimumDisplay))
    }

    func testFirstFrameAfterMinimumDismissesImmediatelyWithNoAddedDelay() {
        let firstFrameAt = shownAt.advanced(by: .milliseconds(5000))

        let dismissAt = PaneLoaderPolicy.dismissAt(shownAt: shownAt, firstFrameAt: firstFrameAt)

        XCTAssertEqual(dismissAt, firstFrameAt)
    }

    func testFirstFrameExactlyAtTheMinimumDismissesAtThatInstant() {
        let firstFrameAt = shownAt.advanced(by: PaneLoaderPolicy.minimumDisplay)

        let dismissAt = PaneLoaderPolicy.dismissAt(shownAt: shownAt, firstFrameAt: firstFrameAt)

        XCTAssertEqual(dismissAt, firstFrameAt)
    }

    func testACustomMinimumIsHonoredJustLikeTheDefault() {
        let firstFrameAt = shownAt.advanced(by: .milliseconds(10))

        let dismissAt = PaneLoaderPolicy.dismissAt(shownAt: shownAt, firstFrameAt: firstFrameAt, minimum: .milliseconds(500))

        XCTAssertEqual(dismissAt, shownAt.advanced(by: .milliseconds(500)))
    }
}
