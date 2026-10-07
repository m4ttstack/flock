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

    func testTheFitHoldsStillWhileADragIsLive() {
        var hold = IslandFitHold()
        let first = hold.update(islands([2]), in: CGSize(width: 1700, height: 1000), dragging: false)
        let during = hold.update(islands([2, 6, 6, 6]), in: CGSize(width: 900, height: 500), dragging: true)
        XCTAssertEqual(first, during)
        let after = hold.update(islands([2, 6, 6, 6]), in: CGSize(width: 900, height: 500), dragging: false)
        XCTAssertNotEqual(first, after)
    }
}
