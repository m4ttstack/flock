import XCTest
@testable import FlockCore

final class StripTabOrderTests: XCTestCase {
    private func tab(_ n: Int) -> TabRecord {
        TabRecord(
            tabID: TabID(rawValue: "w1:t\(n)"), workspaceID: WorkspaceID(rawValue: "w1"), label: "\(n)",
            number: n, paneCount: 1, agentStatus: .idle
        )
    }

    private func ids(_ ns: Int...) -> [TabID] { ns.map { TabID(rawValue: "w1:t\($0)") } }

    func testCompleteTabsFollowTheOpenOnesEachInHerdrsOrder() {
        let complete = Set(ids(1, 3))
        let ordered = StripTabOrder.ordered((1...5).map(tab), isComplete: complete.contains)

        XCTAssertEqual(ordered.map(\.tabID), ids(2, 4, 5, 1, 3))
    }

    func testWithNothingCompleteTheStripIsHerdrsOrder() {
        XCTAssertEqual(StripTabOrder.ordered((1...3).map(tab), isComplete: { _ in false }).map(\.tabID), ids(1, 2, 3))
    }

    /// A slot before the strip's nth tab lands before that same tab in herdr's
    /// list; a slot past the last lands at herdr's end.
    func testAStripSlotLandsBeforeTheTabItSitsBefore() {
        let model = ids(1, 2, 3, 4, 5)
        let strip = ids(2, 4, 5, 1, 3)

        let complete = Set(ids(1, 3))
        let open = ids(4)[0]

        func slot(_ stripIndex: Int, moving: TabID) -> Int {
            StripTabOrder.modelInsertIndex(forStripIndex: stripIndex, moving: moving, strip: strip, model: model, complete: complete)
        }

        XCTAssertEqual(slot(0, moving: open), 1)
        XCTAssertEqual(slot(2, moving: open), 4)
        XCTAssertEqual(slot(5, moving: ids(1)[0]), 5)
    }

    /// The first complete tab can sit ahead of every open tab in herdr's list,
    /// and landing before it there would put the dragged tab first.
    func testTheEndOfTheOpenRunLandsAfterTheLastOpenTab() {
        let model = ids(1, 2, 3, 4, 5)
        let strip = ids(2, 4, 5, 1, 3)

        XCTAssertEqual(
            StripTabOrder.modelInsertIndex(forStripIndex: 3, moving: ids(2)[0], strip: strip, model: model, complete: Set(ids(1, 3))),
            5
        )
    }

    func testACompleteTabAtTheHeadOfItsRunLandsBeforeTheFirstCompleteTab() {
        let model = ids(1, 2, 3, 4, 5)
        let strip = ids(2, 4, 5, 1, 3)

        XCTAssertEqual(
            StripTabOrder.modelInsertIndex(forStripIndex: 3, moving: ids(3)[0], strip: strip, model: model, complete: Set(ids(1, 3))),
            0
        )
    }

    func testTheLastOpenTabHeldAtTheEndOfItsRunStaysPut() {
        let model = ids(1, 2, 3, 4, 5)
        let strip = ids(2, 4, 5, 1, 3)
        let index = StripTabOrder.modelInsertIndex(forStripIndex: 3, moving: ids(5)[0], strip: strip, model: model, complete: Set(ids(1, 3)))

        XCTAssertEqual(ReshuffleOffset.landedSlot(forItemAt: 4, draggingIndex: 4, insertIndex: index), 4)
    }

    func testARunStopsAtTheOtherRun() {
        let strip = ids(2, 4, 5, 1, 3)
        let complete = Set(ids(1, 3))

        XCTAssertEqual(StripTabOrder.run(of: ids(4)[0], strip: strip, complete: complete), 0..<3)
        XCTAssertEqual(StripTabOrder.run(of: ids(1)[0], strip: strip, complete: complete), 3..<5)
    }

    /// Widths differ, and the free run before the complete group is wider than
    /// any tab: the moved tab still lands flush against its new neighbor.
    func testAReorderSlidesEachTabIntoItsOwnSlot() {
        let gap: CGFloat = 3
        let widths: [CGFloat] = [200, 100, 120]
        var items: [CGRect] = []
        var x: CGFloat = 0
        for width in widths {
            items.append(CGRect(x: x, y: 0, width: width, height: 30))
            x += width + gap
        }
        items.append(CGRect(x: 900, y: 0, width: 60, height: 30))
        let run = 0..<3

        let landed = run.map { items[$0].minX + StripTabOrder.displacement(forItemAt: $0, dragging: 0, insertIndex: 3, run: run, items: items) }

        XCTAssertEqual(landed, [226, 0, 103])
        XCTAssertEqual(StripTabOrder.displacement(forItemAt: 3, dragging: 0, insertIndex: 3, run: run, items: items), 0)
    }

    func testMovingTheLastOpenTabLeftIgnoresTheFreeRun() {
        let items = [
            CGRect(x: 0, y: 0, width: 100, height: 30),
            CGRect(x: 103, y: 0, width: 100, height: 30),
            CGRect(x: 900, y: 0, width: 60, height: 30)
        ]

        XCTAssertEqual(StripTabOrder.displacement(forItemAt: 0, dragging: 1, insertIndex: 0, run: 0..<2, items: items), 103)
    }

    func testWithNothingCompleteASlotIsUnchanged() {
        let order = ids(1, 2, 3)
        for slot in 0...3 {
            XCTAssertEqual(
                StripTabOrder.modelInsertIndex(forStripIndex: slot, moving: order[0], strip: order, model: order, complete: []),
                slot
            )
        }
    }
}
