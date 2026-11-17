import XCTest
@testable import FlockCore

/// What the canvas shows the instant a pane among siblings closes, before
/// herdr's own `layout.updated` arrives: the pane's sibling takes the split's
/// whole rect, and the tree under it moves up one level.
@MainActor
final class PaneClosePredictionTests: XCTestCase {
    /// One tab, area 20x10: `p1` on the left half, and on the right half a
    /// down split of `p2` over `p3`, named in herdr's own id scheme.
    private func threePaneModel(focused: String = "w1:p1") throws -> SessionModel {
        let json = #"""
        {"version":"0.9.0","protocol":22,"focused_workspace_id":"w1","focused_tab_id":"w1:t1","focused_pane_id":"\#(focused)","workspaces":[{"workspace_id":"w1","label":"acme","number":1,"active_tab_id":"w1:t1","agent_status":"unknown"}],"tabs":[{"tab_id":"w1:t1","workspace_id":"w1","label":"1","number":1,"pane_count":3,"agent_status":"unknown"}],"panes":[{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1","focused":false,"agent_status":"unknown","revision":0,"cwd":"/tmp"},{"pane_id":"w1:p2","workspace_id":"w1","tab_id":"w1:t1","focused":false,"agent_status":"unknown","revision":0,"cwd":"/tmp"},{"pane_id":"w1:p3","workspace_id":"w1","tab_id":"w1:t1","focused":false,"agent_status":"unknown","revision":0,"cwd":"/tmp"}],"layouts":[{"workspace_id":"w1","tab_id":"w1:t1","zoomed":false,"area":{"x":0,"y":0,"width":20,"height":10},"focused_pane_id":"\#(focused)","panes":[{"pane_id":"w1:p1","focused":false,"rect":{"x":0,"y":0,"width":10,"height":10}},{"pane_id":"w1:p2","focused":false,"rect":{"x":10,"y":0,"width":10,"height":5}},{"pane_id":"w1:p3","focused":false,"rect":{"x":10,"y":5,"width":10,"height":5}}],"splits":[{"id":"split_t1_root","direction":"right","ratio":0.5,"rect":{"x":0,"y":0,"width":20,"height":10}},{"id":"split_t1_1","direction":"down","ratio":0.5,"rect":{"x":10,"y":0,"width":10,"height":10}}]}]}
        """#
        return SessionModel(snapshot: try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8)))
    }

    private func rect(_ layout: LayoutSnapshot?, _ pane: String) -> CellRect? {
        layout?.panes.first { $0.paneID == PaneID(rawValue: pane) }?.rect
    }

    func testALeafSiblingTakesTheWholeSplit() throws {
        let layout = HerdrStore.predictedLayout(removing: PaneID(rawValue: "w1:p2"), model: try threePaneModel())

        XCTAssertNil(rect(layout, "w1:p2"))
        XCTAssertEqual(rect(layout, "w1:p3"), CellRect(x: 10, y: 0, width: 10, height: 10))
        XCTAssertEqual(rect(layout, "w1:p1"), CellRect(x: 0, y: 0, width: 10, height: 10), "a pane outside the split moved")
        XCTAssertEqual(layout?.splits.map(\.id), ["split_t1_root"])
    }

    /// The subtree moves up a level, so its split takes the root's place and
    /// its herdr id is renamed for that place.
    func testASubtreeSiblingMovesUpALevel() throws {
        let layout = HerdrStore.predictedLayout(removing: PaneID(rawValue: "w1:p1"), model: try threePaneModel())

        XCTAssertEqual(rect(layout, "w1:p2"), CellRect(x: 0, y: 0, width: 20, height: 5))
        XCTAssertEqual(rect(layout, "w1:p3"), CellRect(x: 0, y: 5, width: 20, height: 5))
        XCTAssertEqual(layout?.splits.map(\.id), ["split_t1_root"])
        XCTAssertEqual(layout?.splits.first?.direction, .down)
        XCTAssertEqual(layout?.splits.first?.rect, CellRect(x: 0, y: 0, width: 20, height: 10))
    }

    /// herdr says where focus goes after a close; until then nothing names
    /// the pane that left.
    func testFocusOnTheClosedPaneIsDropped() throws {
        let layout = HerdrStore.predictedLayout(removing: PaneID(rawValue: "w1:p1"), model: try threePaneModel(focused: "w1:p1"))

        XCTAssertNil(layout?.focusedPaneID)
    }

    func testAZoomedTabPredictsNothing() throws {
        var model = try threePaneModel()
        let layout = try XCTUnwrap(model.layouts[TabID(rawValue: "w1:t1")])
        model.layouts[layout.tabID] = LayoutSnapshot(
            workspaceID: layout.workspaceID, tabID: layout.tabID, zoomed: true, area: layout.area,
            focusedPaneID: layout.focusedPaneID, panes: layout.panes, splits: layout.splits
        )

        XCTAssertNil(HerdrStore.predictedLayout(removing: PaneID(rawValue: "w1:p2"), model: model))
    }
}
