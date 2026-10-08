import XCTest
@testable import FlockCore

final class ExternalFocusWatchTests: XCTestCase {
    private let a = PaneID(rawValue: "w1:p1")
    private let b = PaneID(rawValue: "w2:p1")
    private let c = PaneID(rawValue: "w3:p1")
    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    func testAMoveWhileAwayCountsOnComingBack() {
        var watch = ExternalFocusWatch()
        watch.left(focus: a)
        XCTAssertTrue(watch.returned(focus: b, ownTarget: nil, at: t0))
    }

    func testComingBackToTheSameFocusIsNotAMove() {
        var watch = ExternalFocusWatch()
        watch.left(focus: a)
        XCTAssertFalse(watch.returned(focus: a, ownTarget: nil, at: t0))
    }

    func testComingToTheFrontWithoutHavingLeftIsNotAMove() {
        var watch = ExternalFocusWatch()
        XCTAssertFalse(watch.returned(focus: b, ownTarget: nil, at: t0))
    }

    func testAMoveWhileInFrontIsFlocksOwn() {
        var watch = ExternalFocusWatch()
        XCTAssertFalse(watch.observed(focus: b, ownTarget: nil, at: t0))
    }

    func testAMoveTrailingTheRaiseCountsOnce() {
        var watch = ExternalFocusWatch()
        watch.left(focus: a)
        XCTAssertFalse(watch.returned(focus: a, ownTarget: nil, at: t0))
        XCTAssertFalse(watch.observed(focus: a, ownTarget: nil, at: at(0.1)))
        XCTAssertTrue(watch.observed(focus: b, ownTarget: nil, at: at(0.2)))
        XCTAssertFalse(watch.observed(focus: c, ownTarget: nil, at: at(0.3)))
    }

    func testAMoveAfterTheGraceIsFlocksOwn() {
        var watch = ExternalFocusWatch()
        watch.left(focus: a)
        _ = watch.returned(focus: a, ownTarget: nil, at: t0)
        XCTAssertFalse(watch.observed(focus: b, ownTarget: nil, at: at(ExternalFocusWatch.grace + 0.1)))
    }

    func testOverviewsOwnPaneIsNeverAMove() {
        var watch = ExternalFocusWatch()
        watch.left(focus: a)
        XCTAssertFalse(watch.returned(focus: b, ownTarget: b, at: t0), "landed before the raise")
        XCTAssertFalse(watch.observed(focus: b, ownTarget: b, at: at(0.1)), "landed after it")
    }

    func testOverviewsOwnPaneLeavesTheGraceArmed() {
        var watch = ExternalFocusWatch()
        watch.left(focus: a)
        _ = watch.returned(focus: a, ownTarget: b, at: t0)
        XCTAssertFalse(watch.observed(focus: b, ownTarget: b, at: at(0.1)))
        XCTAssertTrue(watch.observed(focus: c, ownTarget: b, at: at(0.2)))
    }

    /// Overview's cards flipped quickly: b's echo lands while c is shown.
    func testAPaneFlockQueuedSinceComingBackIsNeverAMove() {
        var watch = ExternalFocusWatch()
        watch.left(focus: a)
        _ = watch.returned(focus: a, ownTarget: a, at: t0)
        watch.flockQueued(b)
        watch.flockQueued(c)
        XCTAssertFalse(watch.observed(focus: b, ownTarget: c, at: at(0.1)))
        XCTAssertFalse(watch.observed(focus: c, ownTarget: c, at: at(0.2)))
    }

    func testQueuedPanesAreForgottenOnLeaving() {
        var watch = ExternalFocusWatch()
        watch.left(focus: a)
        _ = watch.returned(focus: a, ownTarget: nil, at: t0)
        watch.flockQueued(b)
        watch.left(focus: a)
        XCTAssertTrue(watch.returned(focus: b, ownTarget: nil, at: at(0.5)))
    }

    func testAnUnknownFocusIsNotAMoveAndLeavesTheGraceArmed() {
        var watch = ExternalFocusWatch()
        watch.left(focus: a)
        XCTAssertFalse(watch.returned(focus: nil, ownTarget: nil, at: t0))
        XCTAssertFalse(watch.observed(focus: nil, ownTarget: nil, at: at(0.1)))
        XCTAssertTrue(watch.observed(focus: b, ownTarget: nil, at: at(0.2)))

        var unknownWhenLeft = ExternalFocusWatch()
        unknownWhenLeft.left(focus: nil)
        XCTAssertFalse(unknownWhenLeft.returned(focus: b, ownTarget: nil, at: t0))
    }

    func testLeavingAgainEndsTheGrace() {
        var watch = ExternalFocusWatch()
        watch.left(focus: a)
        _ = watch.returned(focus: a, ownTarget: nil, at: t0)
        watch.left(focus: a)
        XCTAssertFalse(watch.observed(focus: b, ownTarget: nil, at: at(0.1)))
        XCTAssertTrue(watch.returned(focus: b, ownTarget: nil, at: at(0.2)))
    }
}
