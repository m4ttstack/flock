import XCTest
@testable import FlockCore

final class ExternalFocusWatchTests: XCTestCase {
    private let a = PaneID(rawValue: "w1:p1")
    private let b = PaneID(rawValue: "w2:p1")
    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    func testAMoveWhileAwayCountsOnComingBack() {
        var watch = ExternalFocusWatch()
        watch.left(focus: a)
        XCTAssertTrue(watch.returned(focus: b, at: t0))
    }

    func testComingBackToTheSameFocusIsNotAMove() {
        var watch = ExternalFocusWatch()
        watch.left(focus: a)
        XCTAssertFalse(watch.returned(focus: a, at: t0))
    }

    func testComingToTheFrontWithoutHavingLeftIsNotAMove() {
        var watch = ExternalFocusWatch()
        XCTAssertFalse(watch.returned(focus: b, at: t0))
    }

    func testAMoveWhileInFrontIsFlocksOwn() {
        var watch = ExternalFocusWatch()
        XCTAssertFalse(watch.observed(focus: b, ownTarget: nil, at: t0))
    }

    func testAMoveTrailingTheRaiseCountsOnce() {
        var watch = ExternalFocusWatch()
        watch.left(focus: a)
        XCTAssertFalse(watch.returned(focus: a, at: t0))
        XCTAssertFalse(watch.observed(focus: a, ownTarget: nil, at: t0.addingTimeInterval(0.1)))
        XCTAssertTrue(watch.observed(focus: b, ownTarget: nil, at: t0.addingTimeInterval(0.2)))
        XCTAssertFalse(watch.observed(focus: a, ownTarget: nil, at: t0.addingTimeInterval(0.3)))
    }

    func testAMoveAfterTheGraceIsFlocksOwn() {
        var watch = ExternalFocusWatch()
        watch.left(focus: a)
        _ = watch.returned(focus: a, at: t0)
        XCTAssertFalse(watch.observed(focus: b, ownTarget: nil, at: t0.addingTimeInterval(ExternalFocusWatch.grace + 0.1)))
    }

    func testOverviewsOwnPaneInsideTheGraceIsFlocksOwn() {
        var watch = ExternalFocusWatch()
        watch.left(focus: a)
        _ = watch.returned(focus: a, at: t0)
        XCTAssertFalse(watch.observed(focus: b, ownTarget: b, at: t0.addingTimeInterval(0.1)))
        XCTAssertFalse(watch.observed(focus: a, ownTarget: nil, at: t0.addingTimeInterval(0.2)))
    }

    func testLeavingAgainEndsTheGrace() {
        var watch = ExternalFocusWatch()
        watch.left(focus: a)
        _ = watch.returned(focus: a, at: t0)
        watch.left(focus: a)
        XCTAssertFalse(watch.observed(focus: b, ownTarget: nil, at: t0.addingTimeInterval(0.1)))
        XCTAssertTrue(watch.returned(focus: b, at: t0.addingTimeInterval(0.2)))
    }
}
