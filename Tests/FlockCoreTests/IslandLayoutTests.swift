import XCTest
@testable import FlockCore

final class IslandLayoutTests: XCTestCase {
    private func islands(_ tabs: [Int]) -> [IslandLayout.Island] {
        tabs.enumerated().map { IslandLayout.Island(id: WorkspaceID(rawValue: "w\($0.offset + 1)"), tabs: $0.element) }
    }

    func testAFewSmallWorkspacesGetTheCap() {
        let fit = IslandLayout.fit(islands([1, 2]), in: CGSize(width: 1700, height: 1000), hasDormantStrip: false)
        XCTAssertEqual(fit.thumbnailWidth, 320)
        XCTAssertFalse(fit.scrolls)
    }

    func testTheLargestWidthThatFitsIsChosen() {
        let metrics = IslandLayout.Metrics()
        let size = CGSize(width: 1750, height: 980)
        let fit = IslandLayout.fit(islands([3, 2, 1, 1, 3, 5, 1, 1, 2, 1, 1, 1]), in: size, hasDormantStrip: true)
        XCTAssertFalse(fit.scrolls)
        XCTAssertLessThan(fit.thumbnailWidth, 320)
        let bigger = IslandLayout.fit(islands([3, 2, 1, 1, 3, 5, 1, 1, 2, 1, 1, 1]), in: size, hasDormantStrip: true, metrics: {
            var m = metrics; m.minimumWidth = fit.thumbnailWidth + metrics.step; return m
        }())
        XCTAssertTrue(bigger.scrolls, "one step larger no longer fits")
    }

    func testTooManyWorkspacesScrollAtTheFloor() {
        let fit = IslandLayout.fit(islands(Array(repeating: 4, count: 40)), in: CGSize(width: 900, height: 600), hasDormantStrip: false)
        XCTAssertEqual(fit.thumbnailWidth, 120)
        XCTAssertTrue(fit.scrolls)
    }

    func testIslandsPackLeftToRightInOrderAndWrap() {
        let fit = IslandLayout.fit(islands([3, 3, 3]), in: CGSize(width: 1300, height: 400), hasDormantStrip: false)
        XCTAssertEqual(fit.rows.flatMap { $0 }.map(\.rawValue), ["w1", "w2", "w3"])
        XCTAssertGreaterThan(fit.rows.count, 1)
    }

    func testAnIslandWiderThanTheWindowWrapsItsTabs() {
        let fit = IslandLayout.fit(islands([12]), in: CGSize(width: 900, height: 2000), hasDormantStrip: false)
        let perRow = try! XCTUnwrap(fit.tabsPerRow[WorkspaceID(rawValue: "w1")])
        XCTAssertLessThan(perRow, 12)
        XCTAssertLessThanOrEqual(IslandLayout.width(tabs: 12, perRow: perRow, thumbnail: fit.thumbnailWidth, metrics: .init()), 900)
    }

    func testTheFitHoldsStillWhileADragIsLive() {
        var hold = IslandFitHold()
        let first = hold.update(islands([2]), in: CGSize(width: 1700, height: 1000), hasDormantStrip: false, dragging: false)
        let during = hold.update(islands([2, 6, 6, 6]), in: CGSize(width: 900, height: 500), hasDormantStrip: false, dragging: true)
        XCTAssertEqual(first, during)
        let after = hold.update(islands([2, 6, 6, 6]), in: CGSize(width: 900, height: 500), hasDormantStrip: false, dragging: false)
        XCTAssertNotEqual(first, after)
    }

    func testAnIslandSprungOpenMidDragGoesBelowTheHeldRowsAtTheHeldSize() {
        let held = IslandLayout.fit(islands([3, 2]), in: CGSize(width: 1300, height: 800), hasDormantStrip: true)
        let sprung = IslandLayout.Island(id: WorkspaceID(rawValue: "w9"), tabs: 12)
        let grown = held.appending([sprung], width: 1300)
        XCTAssertEqual(Array(grown.rows.prefix(held.rows.count)), held.rows, "an island already drawn moved")
        XCTAssertEqual(grown.rows.last, [sprung.id])
        XCTAssertEqual(grown.thumbnailWidth, held.thumbnailWidth)
        XCTAssertEqual(grown.thumbnailHeight, held.thumbnailHeight)
        let perRow = try! XCTUnwrap(grown.tabsPerRow[sprung.id])
        XCTAssertLessThanOrEqual(IslandLayout.width(tabs: 12, perRow: perRow, thumbnail: held.thumbnailWidth, metrics: .init()), 1300)
        XCTAssertEqual(held.appending([], width: 1300), held)
    }
}
