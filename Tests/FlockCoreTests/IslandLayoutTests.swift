import XCTest
@testable import FlockCore

final class IslandLayoutTests: XCTestCase {
    private func islands(_ tabs: [Int]) -> [IslandLayout.Island] {
        tabs.enumerated().map { IslandLayout.Island(id: WorkspaceID(rawValue: "w\($0.offset + 1)"), tabs: $0.element) }
    }

    func testAFewSmallWorkspacesGetTheCap() {
        let fit = IslandLayout.fit(islands([1, 2]), in: CGSize(width: 1700, height: 1000))
        XCTAssertEqual(fit.thumbnailWidth, IslandLayout.Metrics().maximumWidth)
        XCTAssertFalse(fit.scrolls)
    }

    func testTheLargestWidthThatFitsIsChosen() {
        let metrics = IslandLayout.Metrics()
        let size = CGSize(width: 1400, height: 656)
        let fit = IslandLayout.fit(islands([3, 2, 1, 1, 3, 5, 1, 1, 2, 1, 1, 1]), in: size)
        XCTAssertFalse(fit.scrolls)
        XCTAssertLessThan(fit.thumbnailWidth, metrics.maximumWidth)
        let bigger = IslandLayout.fit(islands([3, 2, 1, 1, 3, 5, 1, 1, 2, 1, 1, 1]), in: size, metrics: {
            var m = metrics; m.minimumWidth = fit.thumbnailWidth + metrics.step; return m
        }())
        XCTAssertTrue(bigger.scrolls, "one step larger no longer fits")
    }

    func testTooManyWorkspacesScrollAtTheFloor() {
        let fit = IslandLayout.fit(islands(Array(repeating: 4, count: 40)), in: CGSize(width: 900, height: 600))
        XCTAssertEqual(fit.thumbnailWidth, 120)
        XCTAssertTrue(fit.scrolls)
    }

    func testIslandsPackLeftToRightInOrderAndWrap() {
        let fit = IslandLayout.fit(islands([3, 3, 3]), in: CGSize(width: 1300, height: 400))
        XCTAssertEqual(fit.rows.flatMap { $0 }.map(\.rawValue), ["w1", "w2", "w3"])
        XCTAssertGreaterThan(fit.rows.count, 1)
    }

    func testAnIslandWiderThanTheWindowWrapsItsTabs() {
        let fit = IslandLayout.fit(islands([12]), in: CGSize(width: 900, height: 2000))
        let perRow = try! XCTUnwrap(fit.tabsPerRow[WorkspaceID(rawValue: "w1")])
        XCTAssertLessThan(perRow, 12)
        XCTAssertLessThanOrEqual(IslandLayout.width(tabs: 12, perRow: perRow, thumbnail: fit.thumbnailWidth, metrics: .init()), 900)
    }

    func testAFewWorkspacesGrowPastTheOldFixedSize() {
        let fit = IslandLayout.fit(islands([2, 2, 1, 5]), in: CGSize(width: 1700, height: 1000))
        XCTAssertFalse(fit.scrolls)
        XCTAssertGreaterThan(fit.thumbnailWidth, 260, "four workspaces in a full window still draw at the old cap")
        XCTAssertLessThanOrEqual(fit.thumbnailWidth, IslandLayout.Metrics().maximumWidth)
    }

    func testOneSmallWorkspaceStopsAtTheCap() {
        let fit = IslandLayout.fit(islands([1]), in: CGSize(width: 2400, height: 1400))
        XCTAssertEqual(fit.thumbnailWidth, IslandLayout.Metrics().maximumWidth)
    }

    func testAHerdTooWideForTheWindowWrapsEvenlyToGrow() {
        let size = CGSize(width: 1200, height: 700)
        let fit = IslandLayout.fit(islands([5]), in: size)
        XCTAssertEqual(fit.tabsPerRow[WorkspaceID(rawValue: "w1")], 3, "five tabs wrap three over two")
        let unwrapped = (size.width - 2 * IslandLayout.Metrics().horizontalPadding - 4 * IslandLayout.Metrics().tabGap) / 5
        XCTAssertGreaterThan(fit.thumbnailWidth, unwrapped, "the wrap did not buy a larger thumbnail")
    }

    func testAnIslandThatFitsAtTheCapIsNeverWrapped() {
        let fit = IslandLayout.fit(islands([3, 1]), in: CGSize(width: 2400, height: 1400))
        XCTAssertEqual(fit.tabsPerRow[WorkspaceID(rawValue: "w1")], 3)
        XCTAssertEqual(fit.rows.count, 1)
    }

    func testOnlyTheIslandsOverTheCapWrap() {
        let fit = IslandLayout.fit(islands([2, 6]), in: CGSize(width: 1100, height: 760))
        XCTAssertEqual(fit.tabsPerRow[WorkspaceID(rawValue: "w1")], 2)
        XCTAssertEqual(fit.tabsPerRow[WorkspaceID(rawValue: "w2")], 3, "six tabs wrap three over three")
    }

    func testBalancedRowsNeverLeaveALoneTab() {
        XCTAssertEqual(IslandLayout.balancedAcross(tabs: 5, cap: 4), 3)
        XCTAssertEqual(IslandLayout.balancedAcross(tabs: 5, cap: 3), 3)
        XCTAssertEqual(IslandLayout.balancedAcross(tabs: 5, cap: 2), 2)
        XCTAssertEqual(IslandLayout.balancedAcross(tabs: 6, cap: 4), 3)
        XCTAssertEqual(IslandLayout.balancedAcross(tabs: 2, cap: 9), 2)
        XCTAssertEqual(IslandLayout.balancedAcross(tabs: 0, cap: 3), 1)
    }

    func testTheFitHoldsStillWhileADragIsLive() {
        var hold = IslandFitHold()
        let first = hold.update(islands([2]), in: CGSize(width: 1700, height: 1000), dragging: false)
        let during = hold.update(islands([2, 6, 6, 6]), in: CGSize(width: 900, height: 500), dragging: true)
        XCTAssertEqual(first, during)
        let after = hold.update(islands([2, 6, 6, 6]), in: CGSize(width: 900, height: 500), dragging: false)
        XCTAssertNotEqual(first, after)
    }
}
