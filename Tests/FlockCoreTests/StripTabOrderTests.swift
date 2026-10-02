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

    /// A leading complete tab heads its run; an open one changes nothing.
    func testALeadingCompleteTabHeadsTheCompleteRun() {
        let complete = Set(ids(1, 3, 4))
        let tabs = (1...5).map(tab)

        XCTAssertEqual(StripTabOrder.ordered(tabs, isComplete: complete.contains, leading: ids(4)[0]).map(\.tabID), ids(2, 5, 4, 1, 3))
        XCTAssertEqual(StripTabOrder.ordered(tabs, isComplete: complete.contains, leading: ids(2)[0]).map(\.tabID), ids(2, 5, 1, 3, 4))
    }

    func testWithNothingCompleteTheStripIsHerdrsOrder() {
        XCTAssertEqual(StripTabOrder.ordered((1...3).map(tab), isComplete: { _ in false }).map(\.tabID), ids(1, 2, 3))
    }

    /// A slot before the strip's nth tab lands before that same tab in herdr's
    /// list; a slot past the last lands at herdr's end.
    func testAStripSlotLandsBeforeTheTabItSitsBefore() {
        let model = ids(1, 2, 3, 4, 5)
        let strip = ids(2, 4, 5, 1, 3)

        XCTAssertEqual(StripTabOrder.modelInsertIndex(forStripIndex: 0, strip: strip, model: model), 1)
        XCTAssertEqual(StripTabOrder.modelInsertIndex(forStripIndex: 2, strip: strip, model: model), 4)
        XCTAssertEqual(StripTabOrder.modelInsertIndex(forStripIndex: 3, strip: strip, model: model), 0, "the end of the open run is before the first complete tab")
        XCTAssertEqual(StripTabOrder.modelInsertIndex(forStripIndex: 5, strip: strip, model: model), 5)
    }

    func testWithNothingCompleteASlotIsUnchanged() {
        let order = ids(1, 2, 3)
        for slot in 0...3 {
            XCTAssertEqual(StripTabOrder.modelInsertIndex(forStripIndex: slot, strip: order, model: order), slot)
        }
    }
}
