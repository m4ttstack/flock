import XCTest
@testable import FlockCore

final class ArrangeZoomTests: XCTestCase {
    private let workspace = WorkspaceID(rawValue: "w1")

    func testAZoomNeedsArrangeOpen() {
        var state = AllWorkspacesGridState()
        state.zoom(into: workspace)
        XCTAssertNil(state.zoomed)
        state.open()
        state.zoom(into: workspace)
        XCTAssertEqual(state.zoomed, workspace)
    }

    func testEscTakesTheSelectionThenTheZoomThenArrange() {
        var state = AllWorkspacesGridState()
        state.open()
        state.zoom(into: workspace)
        state.select(pane: PaneID(rawValue: "w1:p1"))
        state.escape()
        XCTAssertNil(state.selected)
        XCTAssertEqual(state.zoomed, workspace)
        state.escape()
        XCTAssertNil(state.zoomed)
        XCTAssertTrue(state.isShown)
        state.escape()
        XCTAssertFalse(state.isShown)
    }

    func testLeavingArrangeForgetsTheZoom() {
        var state = AllWorkspacesGridState()
        state.open()
        state.zoom(into: workspace)
        state.close()
        state.open()
        XCTAssertNil(state.zoomed)
    }

    private func island(_ tabs: Int) -> IslandLayout.Island { IslandLayout.Island(id: workspace, tabs: tabs) }

    private func assertFills(_ fit: IslandLayout.Fit, tabs: Int, _ size: CGSize, file: StaticString = #filePath, line: UInt = #line) {
        let metrics = IslandLayout.Metrics()
        let across = fit.tabsPerRow[workspace] ?? 1
        let rows = CGFloat((tabs + across - 1) / across)
        let width = IslandLayout.width(tabs: tabs, perRow: across, thumbnail: fit.thumbnailWidth, metrics: metrics)
        let height = metrics.headerHeight + rows * fit.thumbnailHeight + (rows - 1) * metrics.tabGap + metrics.bottomPadding
        XCTAssertLessThanOrEqual(width, size.width, file: file, line: line)
        XCTAssertLessThanOrEqual(height, size.height, file: file, line: line)
        XCTAssertGreaterThan(width, size.width - CGFloat(across), "the island leaves the canvas's width unused", file: file, line: line)
        XCTAssertGreaterThan(height, size.height - rows, "the island leaves the canvas's height unused", file: file, line: line)
        XCTAssertFalse(fit.scrolls, file: file, line: line)
    }

    func testTwoTabsZoomSideBySideAndFillTheCanvas() {
        let size = CGSize(width: 1144, height: 620)
        let fit = IslandLayout.zoomFit(island(2), in: size)
        XCTAssertEqual(fit.tabsPerRow[workspace], 2)
        assertFills(fit, tabs: 2, size)
    }

    func testAFiveTabHerdZoomsThreeOverTwo() {
        let size = CGSize(width: 1144, height: 620)
        let fit = IslandLayout.zoomFit(island(5), in: size)
        XCTAssertEqual(fit.tabsPerRow[workspace], 3)
        assertFills(fit, tabs: 5, size)
    }

    func testOneTabTakesTheWholeCanvas() {
        let size = CGSize(width: 1144, height: 620)
        let fit = IslandLayout.zoomFit(island(1), in: size)
        assertFills(fit, tabs: 1, size)
    }

    func testATinyCanvasFloorsTheThumbnailAndScrolls() {
        let fit = IslandLayout.zoomFit(island(6), in: CGSize(width: 200, height: 120))
        XCTAssertEqual(fit.thumbnailWidth, IslandLayout.Metrics().minimumWidth)
        XCTAssertTrue(fit.scrolls)
    }

    func testTheZoomFitHoldsStillWhileADragIsLive() {
        var hold = IslandFitHold()
        let first = hold.update(zoomed: island(2), in: CGSize(width: 1144, height: 620), dragging: false)
        let during = hold.update(zoomed: island(3), in: CGSize(width: 1144, height: 620), dragging: true)
        XCTAssertEqual(first, during)
        let after = hold.update(zoomed: island(3), in: CGSize(width: 1144, height: 620), dragging: false)
        XCTAssertNotEqual(first, after)
    }
}
