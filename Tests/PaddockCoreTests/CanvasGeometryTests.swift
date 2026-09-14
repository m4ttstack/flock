import XCTest
import CoreGraphics
@testable import PaddockCore

final class CanvasGeometryTests: XCTestCase {
    private func grid(filling size: CGSize, scale: CGFloat = 2, phase: CGPoint = .zero) -> CanvasGrid {
        CanvasGrid(canvas: size, phase: phase, displayScale: scale)
    }

    private func layout(splitCount: Int) throws -> LayoutSnapshot {
        let snapshot = try HerdrDecoder.snapshot(fromResponseLine: try fixture("snapshot.json"))
        return try XCTUnwrap(snapshot.layouts.first { $0.splits.count == splitCount })
    }

    func testTwoPaneSplitScalesProportionally() throws {
        let layout = try layout(splitCount: 1)
        let size = CGSize(width: 600, height: 300)
        let geometry = CanvasGeometry(layout: layout, grid: grid(filling: size))

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
        let geometry = CanvasGeometry(layout: layout, grid: grid(filling: size), dividerThickness: 6)

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
        let geometry = CanvasGeometry(layout: layout, grid: grid(filling: CGSize(width: 400, height: 200)))

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
        let geometry = CanvasGeometry(layout: layout, grid: grid(filling: size), dividerThickness: 6)

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
        let geometry = CanvasGeometry(layout: layout, grid: grid(filling: size), dividerThickness: 6)

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
        let rectDerived = CanvasGeometry(layout: layout, grid: grid(filling: size), dividerThickness: 6)

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
            grid: grid(filling: size),
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

        let geometry = CanvasGeometry(layout: degenerate, grid: grid(filling: .zero))

        XCTAssertEqual(geometry.paneFrames[PaneID(rawValue: "w:p1")], .zero)
        XCTAssertTrue(geometry.dividers.isEmpty)
    }

    // MARK: - the canvas is filled, and every edge lands on a device pixel

    func testPaneFramesTileTheWholeCanvasWithNoGapOrOverlap() throws {
        let layout = threePaneLayout(nestedInSecondChild: true)
        // Deliberately indivisible by the 100x50 cell area, at a retina
        // scale: the rounding this forces is where a gap or an overlap would
        // come from.
        let size = CGSize(width: 977, height: 613)
        let geometry = CanvasGeometry(layout: layout, grid: grid(filling: size, scale: 2))

        let frames = try ["other", "top", "bottom"].map { name in
            try XCTUnwrap(geometry.paneFrames[PaneID(rawValue: name)])
        }
        let covered = frames.reduce(into: 0 as CGFloat) { $0 += $1.width * $1.height }
        XCTAssertEqual(covered, size.width * size.height, accuracy: 0.001, "the panes cover the canvas exactly")
        XCTAssertEqual(frames.map(\.minX).min(), 0)
        XCTAssertEqual(frames.map(\.minY).min(), 0)
        XCTAssertEqual(frames.map(\.maxX).max(), size.width)
        XCTAssertEqual(frames.map(\.maxY).max(), size.height)
        for (index, frame) in frames.enumerated() {
            for other in frames[(index + 1)...] {
                XCTAssertFalse(frame.intersects(other), "\(frame) overlaps \(other)")
            }
        }
    }

    func testEveryFrameEdgeLandsOnAWholeDevicePixelAtTheCanvasPhase() {
        let layout = threePaneLayout(nestedInSecondChild: true)
        let size = CGSize(width: 977, height: 613)
        // The canvas does not itself begin on a whole device pixel, so a
        // frame snapped as if it did would still leave the surface on a
        // fractional one.
        let phase = CGPoint(x: 64.25, y: 30.75)
        let scale: CGFloat = 2
        let geometry = CanvasGeometry(layout: layout, grid: grid(filling: size, scale: scale, phase: phase))

        for (pane, frame) in geometry.paneFrames {
            let edges = [
                ("minX", frame.minX + phase.x), ("maxX", frame.maxX + phase.x),
                ("minY", frame.minY + phase.y), ("maxY", frame.maxY + phase.y),
            ]
            for (axis, value) in edges {
                let pixels = value * scale
                XCTAssertEqual(
                    pixels, pixels.rounded(), accuracy: 0.0001,
                    "\(pane.rawValue) \(axis) sits at \(value)pt, a fractional device pixel")
            }
        }
    }

    /// A canvas 1001pt wide over a 100-cell area puts the shared edge at
    /// 500.5pt, which is a whole HALF pixel and not a whole third: the raw
    /// value passes a scale-2 check and fails a scale-3 one, so it can tell
    /// snapping-to-thirds apart from snapping-to-halves and from no snapping
    /// at all.
    func testAThirdScaleSnapsToThirdsNotHalvesOrNothing() throws {
        let layout = threePaneLayout(nestedInSecondChild: true)
        let geometry = CanvasGeometry(layout: layout, grid: grid(filling: CGSize(width: 1001, height: 613), scale: 3))

        let left = try XCTUnwrap(geometry.paneFrames[PaneID(rawValue: "other")])
        XCTAssertNotEqual(
            left.maxX, 500.5, accuracy: 0.0001,
            "the raw proportional edge is not on a third, so it must have moved")
        XCTAssertEqual(
            left.maxX * 3, (left.maxX * 3).rounded(), accuracy: 0.0001,
            "the snapped edge sits on a whole third of a point")
    }

    // MARK: - SurfaceGrid (whole cells only, the remainder left as padding)

    func testSurfaceGridFloorsToWholeCellsAndSizesToThem() {
        let fit = SurfaceGrid.fit(inner: CGSize(width: 103, height: 61), cell: CGSize(width: 10, height: 20))

        XCTAssertEqual(fit.cols, 10)
        XCTAssertEqual(fit.rows, 3)
        XCTAssertEqual(fit.size, CGSize(width: 100, height: 60), "the sub-cell remainder is never rendered")
    }

    /// herdr clamps a pane to 4x2 whatever it is asked for, so a smaller grid
    /// would leave the surface rendering cols/rows the real pane does not have
    /// and the mouse cell clamp reading the wrong grid.
    func testSurfaceGridNeverGoesBelowHerdrsOwnFloor() {
        let fit = SurfaceGrid.fit(inner: CGSize(width: 3, height: 2), cell: CGSize(width: 10, height: 20))

        XCTAssertEqual(fit.cols, SurfaceGrid.minimumCols)
        XCTAssertEqual(fit.rows, SurfaceGrid.minimumRows)
        XCTAssertEqual(fit.cols, 4)
        XCTAssertEqual(fit.rows, 2)
        XCTAssertEqual(fit.size, CGSize(width: 40, height: 40), "the surface covers the grid herdr will actually apply")
    }

    func testSurfaceGridWithNoMeasuredCellYieldsNoSurfaceAtTheFloor() {
        let fit = SurfaceGrid.fit(inner: CGSize(width: 100, height: 100), cell: .zero)

        XCTAssertEqual(fit.size, .zero)
        XCTAssertEqual(fit.cols, SurfaceGrid.minimumCols)
        XCTAssertEqual(fit.rows, SurfaceGrid.minimumRows)
    }

    // MARK: - PaneBox (the gutter inset, never a negative frame)

    func testPaneBoxInsetsByHalfTheGutterOnEverySide() {
        let box = PaneBox.frame(in: CGRect(x: 100, y: 40, width: 300, height: 200), dividerThickness: 6)

        XCTAssertEqual(box, CGRect(x: 103, y: 43, width: 294, height: 194))
    }

    /// Enough splits in a small window (or a transient zero-size layout pass)
    /// yields a frame narrower than the gutter; SwiftUI rejects a negative
    /// frame, so the box collapses to empty instead.
    func testPaneBoxNeverProducesANegativeSize() {
        let box = PaneBox.frame(in: CGRect(x: 10, y: 10, width: 4, height: 1), dividerThickness: 6)

        XCTAssertEqual(box.width, 0)
        XCTAssertEqual(box.height, 0)
    }

    // MARK: - Translating into an outer space (drop hit-testing)

    func testOffsetMovesEveryPaneFrameAndDivider() throws {
        let layout = try layout(splitCount: 1)
        let geometry = CanvasGeometry(layout: layout, grid: grid(filling: CGSize(width: 600, height: 300)))
        let moved = geometry.offset(by: CGPoint(x: 216, y: 86))

        let before = try XCTUnwrap(geometry.paneFrames[PaneID(rawValue: "w1:p1")])
        let after = try XCTUnwrap(moved.paneFrames[PaneID(rawValue: "w1:p1")])
        XCTAssertEqual(after, before.offsetBy(dx: 216, dy: 86))
        XCTAssertEqual(moved.dividers.count, geometry.dividers.count)
        XCTAssertEqual(moved.dividers.first?.frame, geometry.dividers.first?.frame.offsetBy(dx: 216, dy: 86))
    }

    /// `.empty` exists so a window with no selected tab still has something to
    /// hit-test against, so it is checked through the resolver rather than by
    /// restating its own definition: the same point that finds a pane on a
    /// real canvas finds nothing on this one.
    func testEmptyGeometryResolvesNoCanvasTarget() throws {
        let layout = try layout(splitCount: 1)
        let real = CanvasGeometry(layout: layout, grid: grid(filling: CGSize(width: 600, height: 300)))
        let point = CGPoint(x: 150, y: 150)

        func surfaces(_ canvas: CanvasGeometry) -> DropSurfaces {
            DropSurfaces(
                canvas: canvas, stripWorkspace: WorkspaceID(rawValue: "w1"),
                tabFrames: [], workspaceFrames: [], newTabZone: nil, newWorkspaceZone: nil
            )
        }

        let dragged = DragSubject.pane(PaneID(rawValue: "w1:p2"))
        XCTAssertNotNil(resolveDropTarget(at: point, dragging: dragged, surfaces: surfaces(real)))
        XCTAssertNil(resolveDropTarget(at: point, dragging: dragged, surfaces: surfaces(.empty)))
    }
}
