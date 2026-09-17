import XCTest
@testable import PaddockCore

final class CanvasCompositionTests: XCTestCase {
    private let p1 = PaneID(rawValue: "w1:p1")
    private let p2 = PaneID(rawValue: "w1:p2")

    /// Two panes side by side over a 20x10 area, the same shape herdr reports
    /// for a zoomed tab: the rects never collapse, only `zoomed` moves.
    private func layout(zoomed: Bool, focused: PaneID?) -> LayoutSnapshot {
        let area = CellRect(x: 0, y: 0, width: 20, height: 10)
        return LayoutSnapshot(
            workspaceID: WorkspaceID(rawValue: "w1"),
            tabID: TabID(rawValue: "w1:t1"),
            zoomed: zoomed,
            area: area,
            focusedPaneID: focused,
            panes: [
                PaneRect(paneID: p1, focused: focused == p1, rect: CellRect(x: 0, y: 0, width: 10, height: 10)),
                PaneRect(paneID: p2, focused: focused == p2, rect: CellRect(x: 10, y: 0, width: 10, height: 10)),
            ],
            splits: [SplitInfo(id: "split_0_root", direction: .right, ratio: 0.5, rect: area)]
        )
    }

    func testAnUnzoomedTabIsTiledAndWearsNoBadge() {
        let composition = CanvasComposition.of(layout: layout(zoomed: false, focused: p2))

        XCTAssertEqual(composition, .tiled)
        XCTAssertNil(composition.zoomedPaneID)
    }

    /// The whole point: herdr's renderer holds ONE pane of a zoomed tab open,
    /// so the composition names that pane and the canvas draws it alone --
    /// the rect list still carrying both panes is not an instruction to tile.
    func testAZoomedTabHoldsItsOwnFocusedPaneOpen() {
        let composition = CanvasComposition.of(layout: layout(zoomed: true, focused: p2))

        XCTAssertEqual(composition, .zoomed(p2))
        XCTAssertEqual(composition.zoomedPaneID, p2)
    }

    /// `focusedPane`'s first-pane fallback is a mutation-target rule. Reached
    /// here it would hold open whichever pane the snapshot happens to list
    /// first, so a snapshot that names no focus tiles instead.
    func testAZoomedTabThatNamesNoFocusedPaneStaysTiled() {
        XCTAssertEqual(CanvasComposition.of(layout: layout(zoomed: true, focused: nil)), .tiled)
    }

    /// A focus that is not one of this tab's own panes would name a pane the
    /// canvas has no cell for, leaving an empty canvas rather than a zoom.
    func testAZoomedTabFocusedOnAPaneItDoesNotHoldStaysTiled() {
        let foreign = PaneID(rawValue: "w2:p7")

        XCTAssertEqual(CanvasComposition.of(layout: layout(zoomed: true, focused: foreign)), .tiled)
    }
}
