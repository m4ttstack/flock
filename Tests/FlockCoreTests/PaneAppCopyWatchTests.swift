import XCTest
@testable import FlockCore

final class PaneAppCopyWatchTests: XCTestCase {
    private let pane = PaneID(rawValue: "w1:p1")
    private let other = PaneID(rawValue: "w1:p2")

    func testAChangeInsideTheWindowIsTheArmedPanesCopy() {
        var watch = PaneAppCopyWatch()
        watch.arm(pane: pane, changeCount: 7, now: 10)
        XCTAssertEqual(watch.observe(changeCount: 8, now: 10.3), pane)
        XCTAssertFalse(watch.isArmed)
    }

    func testAnUnchangedCountKeepsWaiting() {
        var watch = PaneAppCopyWatch()
        watch.arm(pane: pane, changeCount: 7, now: 10)
        XCTAssertNil(watch.observe(changeCount: 7, now: 10.5))
        XCTAssertTrue(watch.isArmed)
    }

    func testTheWatchLapsesAtTheDeadline() {
        var watch = PaneAppCopyWatch()
        watch.arm(pane: pane, changeCount: 7, now: 10)
        XCTAssertNil(watch.observe(changeCount: 8, now: 10 + PaneAppCopyWatch.window + 0.01))
        XCTAssertFalse(watch.isArmed)
    }

    func testAChangeIsAttributedOnlyOnce() {
        var watch = PaneAppCopyWatch()
        watch.arm(pane: pane, changeCount: 7, now: 10)
        _ = watch.observe(changeCount: 8, now: 10.2)
        XCTAssertNil(watch.observe(changeCount: 9, now: 10.4))
    }

    func testRearmingMovesTheWatchToTheNewPane() {
        var watch = PaneAppCopyWatch()
        watch.arm(pane: pane, changeCount: 7, now: 10)
        watch.arm(pane: other, changeCount: 7, now: 10.2)
        XCTAssertEqual(watch.observe(changeCount: 8, now: 10.3), other)
    }

    func testAnUnarmedWatchAttributesNothing() {
        var watch = PaneAppCopyWatch()
        XCTAssertNil(watch.observe(changeCount: 8, now: 10))
    }
}
