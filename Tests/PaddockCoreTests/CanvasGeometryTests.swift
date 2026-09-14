import XCTest
import CoreGraphics
@testable import PaddockCore

final class CanvasGeometryTests: XCTestCase {
    /// The proportional grid these fixtures were written against: the area
    /// stretched to fill `size`, origin at the canvas corner.
    private func grid(filling size: CGSize, area: CellRect) -> CanvasGrid {
        CanvasGrid(
            origin: .zero,
            cell: CGSize(width: size.width / CGFloat(area.width), height: size.height / CGFloat(area.height))
        )
    }

    private func layout(splitCount: Int) throws -> LayoutSnapshot {
        let snapshot = try HerdrDecoder.snapshot(fromResponseLine: try fixture("snapshot.json"))
        return try XCTUnwrap(snapshot.layouts.first { $0.splits.count == splitCount })
    }

    func testTwoPaneSplitScalesProportionally() throws {
        let layout = try layout(splitCount: 1)
        let size = CGSize(width: 600, height: 300)
        let geometry = CanvasGeometry(layout: layout, grid: grid(filling: size, area: layout.area))

        let left = try XCTUnwrap(geometry.paneFrames[PaneID(rawValue: "w1:p1")])
        let right = try XCTUnwrap(geometry.paneFrames[PaneID(rawValue: "w1:p2")])

        // fixture ratio is 0.5 over a 54-wide area: each pane covers half the canvas.
        XCTAssertEqual(left.origin.x, 0, accuracy: 1)
        XCTAssertEqual(left.width, 300, accuracy: 1)
        XCTAssertEqual(left.origin.y, 0, accuracy: 1)
        XCTAssertEqual(left.height, 300, accuracy: 1)

        XCTAssertEqual(right.origin.x, left.maxX, accuracy: 1)
        XCTAssertEqual(right.origin.y, left.origin.y, accuracy: 1)
        XCTAssertEqual(right.height, left.height, accuracy: 1)
        XCTAssertEqual(left.width + right.width, size.width, accuracy: 1)
    }

    func testDividerHandleSitsOnSplitBoundary() throws {
        let layout = try layout(splitCount: 1)
        let size = CGSize(width: 600, height: 300)
        let geometry = CanvasGeometry(layout: layout, grid: grid(filling: size, area: layout.area), dividerThickness: 6)

        let divider = try XCTUnwrap(geometry.dividers.first)
        XCTAssertEqual(geometry.dividers.count, 1)
        XCTAssertEqual(divider.path, [])
        XCTAssertEqual(divider.direction, .right)
        XCTAssertEqual(divider.frame.width, 6, accuracy: 0.01)
        XCTAssertEqual(divider.frame.midX, 300, accuracy: 1)
        XCTAssertEqual(divider.frame.origin.y, 0, accuracy: 1)
        XCTAssertEqual(divider.frame.height, size.height, accuracy: 1)
    }

    func testSinglePaneHasNoDividers() throws {
        let layout = try layout(splitCount: 0)
        let geometry = CanvasGeometry(layout: layout, grid: grid(filling: CGSize(width: 400, height: 200), area: layout.area))

        XCTAssertTrue(geometry.dividers.isEmpty)
        XCTAssertEqual(geometry.paneFrames.count, 1)
    }

    /// Synthetic 3-pane layout: root `.right` split at ratio 0.5 over a 100x50
    /// area, with a nested `.down` split (ratio 0.4) placed in either the
    /// root's second-child (right half) or first-child (left half) region.
    /// The nested split is listed BEFORE the root in `splits` to prove path
    /// derivation resolves by containment, not array order.
    private func threePaneLayout(nestedInSecondChild: Bool) -> LayoutSnapshot {
        let area = CellRect(x: 0, y: 0, width: 100, height: 50)
        let rootSplit = SplitInfo(id: "root", direction: .right, ratio: 0.5, rect: area)
        let nestedRegion = nestedInSecondChild
            ? CellRect(x: 50, y: 0, width: 50, height: 50)
            : CellRect(x: 0, y: 0, width: 50, height: 50)
        let otherRegion = nestedInSecondChild
            ? CellRect(x: 0, y: 0, width: 50, height: 50)
            : CellRect(x: 50, y: 0, width: 50, height: 50)
        let nestedSplit = SplitInfo(id: "nested", direction: .down, ratio: 0.4, rect: nestedRegion)

        let topPane = PaneRect(
            paneID: PaneID(rawValue: "top"),
            focused: false,
            rect: CellRect(x: nestedRegion.x, y: nestedRegion.y, width: nestedRegion.width, height: 20)
        )
        let bottomPane = PaneRect(
            paneID: PaneID(rawValue: "bottom"),
            focused: false,
            rect: CellRect(x: nestedRegion.x, y: nestedRegion.y + 20, width: nestedRegion.width, height: 30)
        )
        let otherPane = PaneRect(paneID: PaneID(rawValue: "other"), focused: true, rect: otherRegion)

        return LayoutSnapshot(
            workspaceID: WorkspaceID(rawValue: "w"),
            tabID: TabID(rawValue: "w:t"),
            zoomed: false,
            area: area,
            focusedPaneID: otherPane.paneID,
            panes: [topPane, bottomPane, otherPane],
            splits: [nestedSplit, rootSplit]
        )
    }

    func testNestedSplitInSecondChildRegionGetsTruePath() throws {
        let layout = threePaneLayout(nestedInSecondChild: true)
        let size = CGSize(width: 200, height: 100)
        let geometry = CanvasGeometry(layout: layout, grid: grid(filling: size, area: layout.area), dividerThickness: 6)

        XCTAssertEqual(geometry.dividers.count, 2)

        let root = try XCTUnwrap(geometry.dividers.first { $0.path == [] })
        XCTAssertEqual(root.direction, .right)
        XCTAssertEqual(root.frame.width, 6, accuracy: 0.01)
        XCTAssertEqual(root.frame.midX, 100, accuracy: 1)
        XCTAssertEqual(root.frame.origin.y, 0, accuracy: 1)
        XCTAssertEqual(root.frame.height, size.height, accuracy: 1)

        let nested = try XCTUnwrap(geometry.dividers.first { $0.path == [true] })
        XCTAssertEqual(nested.direction, .down)
        XCTAssertEqual(nested.frame.height, 6, accuracy: 0.01)
        XCTAssertEqual(nested.frame.midY, 40, accuracy: 1)
        XCTAssertEqual(nested.frame.origin.x, 100, accuracy: 1)
        XCTAssertEqual(nested.frame.width, 100, accuracy: 1)

        let leftPane = try XCTUnwrap(geometry.paneFrames[PaneID(rawValue: "other")])
        let topPane = try XCTUnwrap(geometry.paneFrames[PaneID(rawValue: "top")])
        let bottomPane = try XCTUnwrap(geometry.paneFrames[PaneID(rawValue: "bottom")])

        // tiling: the three panes exactly cover the canvas, no gaps or overlaps.
        XCTAssertEqual(leftPane.origin.x, 0, accuracy: 1)
        XCTAssertEqual(leftPane.origin.y, 0, accuracy: 1)
        XCTAssertEqual(leftPane.width, 100, accuracy: 1)
        XCTAssertEqual(leftPane.height, 100, accuracy: 1)
        XCTAssertEqual(topPane.origin.x, leftPane.maxX, accuracy: 1)
        XCTAssertEqual(topPane.origin.y, 0, accuracy: 1)
        XCTAssertEqual(topPane.width, 100, accuracy: 1)
        XCTAssertEqual(topPane.height, 40, accuracy: 1)
        XCTAssertEqual(bottomPane.origin.x, leftPane.maxX, accuracy: 1)
        XCTAssertEqual(bottomPane.origin.y, topPane.maxY, accuracy: 1)
        XCTAssertEqual(bottomPane.width, 100, accuracy: 1)
        XCTAssertEqual(bottomPane.height, 60, accuracy: 1)
    }

    func testNestedSplitInFirstChildRegionGetsFalsePath() throws {
        let layout = threePaneLayout(nestedInSecondChild: false)
        let size = CGSize(width: 200, height: 100)
        let geometry = CanvasGeometry(layout: layout, grid: grid(filling: size, area: layout.area), dividerThickness: 6)

        XCTAssertEqual(geometry.dividers.count, 2)

        let root = try XCTUnwrap(geometry.dividers.first { $0.path == [] })
        XCTAssertEqual(root.direction, .right)
        XCTAssertEqual(root.frame.width, 6, accuracy: 0.01)
        XCTAssertEqual(root.frame.midX, 100, accuracy: 1)

        let nested = try XCTUnwrap(geometry.dividers.first { $0.path == [false] })
        XCTAssertEqual(nested.direction, .down)
        XCTAssertEqual(nested.frame.height, 6, accuracy: 0.01)
        XCTAssertEqual(nested.frame.midY, 40, accuracy: 1)
        XCTAssertEqual(nested.frame.origin.x, 0, accuracy: 1)
        XCTAssertEqual(nested.frame.width, 100, accuracy: 1)
    }

    /// The rect-derivation fixture from the tests above, re-expressed as the
    /// tree `layout.export` would actually return, must produce the same
    /// paneFrames/dividers: this is the fallback's cross-check, proving the
    /// two derivations agree on the canonical fixture.
    func testExportedTreeMapsToSameDividerPathsAsRectDerivation() throws {
        let layout = threePaneLayout(nestedInSecondChild: true)
        let size = CGSize(width: 200, height: 100)
        let rectDerived = CanvasGeometry(layout: layout, grid: grid(filling: size, area: layout.area), dividerThickness: 6)

        let exportedRoot = ExportedLayoutNode.split(
            direction: .right,
            ratio: 0.5,
            first: .pane(ExportedLayoutPane(paneID: PaneID(rawValue: "other"))),
            second: .split(
                direction: .down,
                ratio: 0.4,
                first: .pane(ExportedLayoutPane(paneID: PaneID(rawValue: "top"))),
                second: .pane(ExportedLayoutPane(paneID: PaneID(rawValue: "bottom")))
            )
        )
        let exportedDerived = CanvasGeometry(
            exportedRoot: exportedRoot,
            area: layout.area,
            tabID: layout.tabID,
            grid: grid(filling: size, area: layout.area),
            dividerThickness: 6
        )

        XCTAssertEqual(exportedDerived.paneFrames, rectDerived.paneFrames)

        let rectByPath = Dictionary(uniqueKeysWithValues: rectDerived.dividers.map { ($0.path, $0) })
        let exportedByPath = Dictionary(uniqueKeysWithValues: exportedDerived.dividers.map { ($0.path, $0) })
        XCTAssertEqual(Set(rectByPath.keys), Set(exportedByPath.keys))
        for (path, divider) in rectByPath {
            let matched = try XCTUnwrap(exportedByPath[path])
            XCTAssertEqual(matched.direction, divider.direction)
            XCTAssertEqual(matched.frame, divider.frame)
            XCTAssertEqual(matched.tabID, divider.tabID)
        }
    }

    func testZeroSizeAreaYieldsZeroFramesWithoutCrashing() {
        let degenerate = LayoutSnapshot(
            workspaceID: WorkspaceID(rawValue: "w"),
            tabID: TabID(rawValue: "w:t"),
            zoomed: false,
            area: CellRect(x: 0, y: 0, width: 0, height: 0),
            focusedPaneID: nil,
            panes: [PaneRect(paneID: PaneID(rawValue: "w:p1"), focused: true, rect: CellRect(x: 0, y: 0, width: 0, height: 0))],
            splits: []
        )

        let geometry = CanvasGeometry(layout: degenerate, grid: CanvasGrid(origin: .zero, cell: .zero))

        XCTAssertEqual(geometry.paneFrames[PaneID(rawValue: "w:p1")], .zero)
        XCTAssertTrue(geometry.dividers.isEmpty)
    }
}
