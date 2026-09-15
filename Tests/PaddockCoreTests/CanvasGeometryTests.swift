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

    /// The panes are laid out from whole-cell child regions, so the divider
    /// has to sit on the cell edge the first child actually ends at, not at
    /// `ratio * width`: 0.39 of the fixture's 54 cells rounds to 21 cells,
    /// which is 210pt on a 540pt canvas at 10pt per cell, where the raw ratio
    /// would put the divider at 210.6 and off-center in the gap.
    func testDividerSitsOnTheWholeCellEdgeNotTheRawRatio() throws {
        let layout = try layout(splitCount: 1)
        let size = CGSize(width: 540, height: 300)
        let geometry = CanvasGeometry(
            layout: layout, grid: grid(filling: size, scale: 1), dividerThickness: 12,
            liveRatioOverride: (path: [], ratio: 0.39)
        )

        let divider = try XCTUnwrap(geometry.dividers.first)
        XCTAssertEqual(divider.frame.midX, 210, accuracy: 0.01)
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

    func testPaneBoxSplitsAnOddGutterIntoWholePoints() {
        let box = PaneBox.frame(in: CGRect(x: 100, y: 40, width: 300, height: 200), dividerThickness: 9)

        XCTAssertEqual(box, CGRect(x: 104, y: 44, width: 291, height: 191))
    }

    /// At 1x a half-point inset would put every surface on a fractional device
    /// pixel. An odd gutter must still leave exactly the gutter between two
    /// boxes, with the divider covering exactly that gap.
    func testAnOddGutterKeepsBoxesOnWholePixelsAndTheDividerOnTheGap() throws {
        let layout = try layout(splitCount: 1)
        let geometry = CanvasGeometry(layout: layout, grid: grid(filling: CGSize(width: 540, height: 300), scale: 1), dividerThickness: 9)

        let left = PaneBox.frame(in: try XCTUnwrap(geometry.paneFrames[PaneID(rawValue: "w1:p1")]), dividerThickness: 9)
        let right = PaneBox.frame(in: try XCTUnwrap(geometry.paneFrames[PaneID(rawValue: "w1:p2")]), dividerThickness: 9)
        let divider = try XCTUnwrap(geometry.dividers.first)

        for value in [left.minX, left.minY, right.minX, right.minY] {
            XCTAssertEqual(value, value.rounded(), "box origin \(value) is off the pixel grid")
        }
        XCTAssertEqual(right.minX - left.maxX, 9)
        XCTAssertEqual(divider.frame.minX, left.maxX)
        XCTAssertEqual(divider.frame.maxX, right.minX)
    }

    func testCanvasPaddingPutsEveryOuterBoxEdgeAtTheMargin() {
        let padding = PaneBox.canvasPadding(margin: 6, dividerThickness: 9)
        let canvas = CGRect(x: 0, y: 0, width: 400, height: 300)
        let layoutArea = CGRect(
            x: padding.leadingAndTop, y: padding.leadingAndTop,
            width: canvas.width - padding.leadingAndTop - padding.trailingAndBottom,
            height: canvas.height - padding.leadingAndTop - padding.trailingAndBottom
        )
        let box = PaneBox.frame(in: layoutArea, dividerThickness: 9)

        XCTAssertEqual(box.minX, 6)
        XCTAssertEqual(box.minY, 6)
        XCTAssertEqual(canvas.maxX - box.maxX, 6)
        XCTAssertEqual(canvas.maxY - box.maxY, 6)
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

    // MARK: - DividerHandle.regionFrame / cellExtent (what a divider drag measures against)

    func testDividerRegionFrameIsTheSplitsOwnFullRegionAndCellExtentIsItsAlongAxisCellCount() throws {
        let layout = threePaneLayout(nestedInSecondChild: true)
        let size = CGSize(width: 200, height: 100)
        let geometry = CanvasGeometry(layout: layout, grid: grid(filling: size), dividerThickness: 6)

        let root = try XCTUnwrap(geometry.dividers.first { $0.path == [] })
        XCTAssertEqual(root.regionFrame, CGRect(x: 0, y: 0, width: 200, height: 100))
        XCTAssertEqual(root.cellExtent, 100, "the root's own rect is the whole 100-column area")

        let nested = try XCTUnwrap(geometry.dividers.first { $0.path == [true] })
        XCTAssertEqual(nested.regionFrame, CGRect(x: 100, y: 0, width: 100, height: 100))
        XCTAssertEqual(nested.cellExtent, 50, "the nested split's own rect is 50 rows tall (a `.down` split), not the area's 100 columns")
    }

    /// A root at ratio 0.25 (not the 0.5 every other fixture uses), with a
    /// further split nested in its second child: proves a nested split's
    /// `regionFrame` tracks the ANCESTOR's real ratio-derived boundary, not
    /// a naive halfway split. A midpoint-bisecting derivation would place
    /// the second child at x:100...200; the true one (0.25 of 200) places it
    /// at x:50...200.
    func testNestedRegionFrameTracksANonHalfAncestorRatio() throws {
        let area = CellRect(x: 0, y: 0, width: 200, height: 100)
        let root = SplitInfo(id: "root", direction: .right, ratio: 0.25, rect: area)
        let secondChild = CellRect(x: 50, y: 0, width: 150, height: 100)
        let nested = SplitInfo(id: "nested", direction: .down, ratio: 0.5, rect: secondChild)

        let leftPane = PaneRect(paneID: PaneID(rawValue: "left"), focused: false, rect: CellRect(x: 0, y: 0, width: 50, height: 100))
        let topRightPane = PaneRect(paneID: PaneID(rawValue: "topRight"), focused: false, rect: CellRect(x: 50, y: 0, width: 150, height: 50))
        let bottomRightPane = PaneRect(paneID: PaneID(rawValue: "bottomRight"), focused: true, rect: CellRect(x: 50, y: 50, width: 150, height: 50))

        let layout = LayoutSnapshot(
            workspaceID: WorkspaceID(rawValue: "w"), tabID: TabID(rawValue: "w:t"), zoomed: false, area: area,
            focusedPaneID: bottomRightPane.paneID, panes: [leftPane, topRightPane, bottomRightPane], splits: [nested, root]
        )
        let geometry = CanvasGeometry(layout: layout, grid: grid(filling: CGSize(width: 200, height: 100), scale: 1), dividerThickness: 6)

        let nestedHandle = try XCTUnwrap(geometry.dividers.first { $0.path == [true] })
        XCTAssertEqual(nestedHandle.regionFrame, CGRect(x: 50, y: 0, width: 150, height: 100))
    }

    /// Same shape, a THIRD level: a split nested inside the second nested
    /// split, proving `regionFrame` stays correct two levels deep, not only
    /// at the first nesting. Built through the exported-tree constructor
    /// (the primary render path).
    func testThreeLevelNestedRegionFrameTracksEveryAncestorsOwnRatio() throws {
        let area = CellRect(x: 0, y: 0, width: 200, height: 100)
        let root = ExportedLayoutNode.split(
            direction: .right, ratio: 0.25,
            first: .pane(ExportedLayoutPane(paneID: PaneID(rawValue: "left"))),
            second: .split(
                direction: .down, ratio: 0.2,
                first: .pane(ExportedLayoutPane(paneID: PaneID(rawValue: "top"))),
                second: .split(
                    direction: .right, ratio: 0.5,
                    first: .pane(ExportedLayoutPane(paneID: PaneID(rawValue: "deepLeft"))),
                    second: .pane(ExportedLayoutPane(paneID: PaneID(rawValue: "deepRight")))
                )
            )
        )
        let geometry = CanvasGeometry(
            exportedRoot: root, area: area, tabID: TabID(rawValue: "w:t"),
            grid: grid(filling: CGSize(width: 200, height: 100), scale: 1), dividerThickness: 6
        )

        let deepHandle = try XCTUnwrap(geometry.dividers.first { $0.path == [true, true] })
        XCTAssertEqual(
            deepHandle.regionFrame, CGRect(x: 50, y: 20, width: 150, height: 80),
            "three levels deep, still the true ratio-derived region, not a halved guess"
        )
    }

    /// `splitPaths`'s own structural derivation, exercised through the
    /// rect-derivation fallback: split right, split down in the right half,
    /// split right in the bottom half -- three levels, mixed directions,
    /// `splits` deliberately listed pre-order root-first (herdr's own
    /// emission order). Containment alone resolves the deepest split's
    /// path to `[true]`, colliding with the middle split's own -- both sit
    /// inside the ROOT's second-child region too, not only their true
    /// direct parent's. A structural, direct-children-only match must not
    /// make that mistake.
    func testThreeLevelMixedDirectionNestResolvesDistinctPathsThroughRectDerivation() throws {
        let area = CellRect(x: 0, y: 0, width: 20, height: 20)
        let root = SplitInfo(id: "root", direction: .right, ratio: 0.5, rect: area)
        let rightHalf = CellRect(x: 10, y: 0, width: 10, height: 20)
        let nested = SplitInfo(id: "nested", direction: .down, ratio: 0.5, rect: rightHalf)
        let bottomOfRightHalf = CellRect(x: 10, y: 10, width: 10, height: 10)
        let deep = SplitInfo(id: "deep", direction: .right, ratio: 0.5, rect: bottomOfRightHalf)

        let leftPane = PaneRect(paneID: PaneID(rawValue: "left"), focused: false, rect: CellRect(x: 0, y: 0, width: 10, height: 20))
        let topPane = PaneRect(paneID: PaneID(rawValue: "top"), focused: false, rect: CellRect(x: 10, y: 0, width: 10, height: 10))
        let deepLeftPane = PaneRect(paneID: PaneID(rawValue: "deepLeft"), focused: false, rect: CellRect(x: 10, y: 10, width: 5, height: 10))
        let deepRightPane = PaneRect(paneID: PaneID(rawValue: "deepRight"), focused: true, rect: CellRect(x: 15, y: 10, width: 5, height: 10))

        let layout = LayoutSnapshot(
            workspaceID: WorkspaceID(rawValue: "w"), tabID: TabID(rawValue: "w:t"), zoomed: false, area: area,
            focusedPaneID: deepRightPane.paneID, panes: [leftPane, topPane, deepLeftPane, deepRightPane],
            splits: [root, nested, deep]
        )
        let geometry = CanvasGeometry(layout: layout, grid: grid(filling: CGSize(width: 20, height: 20), scale: 1), dividerThickness: 2)

        XCTAssertEqual(geometry.dividers.count, 3)
        let rootHandle = try XCTUnwrap(geometry.dividers.first { $0.path == [] })
        let nestedHandle = try XCTUnwrap(geometry.dividers.first { $0.path == [true] })
        let deepHandle = try XCTUnwrap(geometry.dividers.first { $0.path == [true, true] })
        XCTAssertEqual(rootHandle.regionFrame, CGRect(x: 0, y: 0, width: 20, height: 20))
        XCTAssertEqual(nestedHandle.regionFrame, CGRect(x: 10, y: 0, width: 10, height: 20))
        XCTAssertEqual(deepHandle.regionFrame, CGRect(x: 10, y: 10, width: 10, height: 10), "the deepest split, not the root it also sits inside of")
    }

    /// Two `.down` splits sharing the same 2-row rect, each at ratio 0.1 --
    /// each one's degenerate second child (`childRegions` rounds the first
    /// to 0 rows) equals the OTHER'S rect exactly, so a bound that only
    /// excludes a split's own id (not a full `visited` set) lets A resolve
    /// to B resolve to A resolve to B forever. A run of this test that
    /// completes at all IS the primary assertion; the fixture-shaped ids
    /// ("root"/"nested") force the structural fallback rather than the
    /// id-parsed primary path, so this exercises the walk's own bound
    /// directly.
    func testTwoMutuallyDegenerateSplitsDoNotRecurseForever() {
        let area = CellRect(x: 0, y: 0, width: 10, height: 2)
        let root = SplitInfo(id: "root", direction: .down, ratio: 0.1, rect: area)
        let nested = SplitInfo(id: "nested", direction: .down, ratio: 0.1, rect: area)

        let paths = CanvasGeometry.splitPaths(splits: [root, nested], area: area)

        XCTAssertEqual(paths.count, 2, "both splits resolve, neither dropped nor looping")
        XCTAssertEqual(Set(paths.values), [[], [true]], "one is the root, the other its distinct second child")
    }

    // MARK: - splitPaths: herdr's own id as the primary path source

    /// herdr's own `split_path_id` shape (`split_<idx>_<digits>`, `1` for a
    /// second-child branch): when every split's id matches it, the id IS
    /// the path, with no tree walk at all. Deliberately shaped so the
    /// id-parsed path and the REAL geometry (`CanvasGeometry`, built from
    /// this same `[SplitInfo]` array and never told about any id) can be
    /// checked against EACH OTHER -- this is what pins the polarity, and it
    /// checks against production code, not a second copy of the rounding
    /// formula: a `0` meaning second-child instead of `1` would place
    /// `deepRight` on the LEFT and `deepLeft` on the right, in the pane
    /// frames `CanvasGeometry` itself produces.
    func testSplitIDsAreParsedAsThePrimaryPathSourceAndThePolarityMatchesTheGeometry() throws {
        let area = CellRect(x: 0, y: 0, width: 20, height: 10)
        let root = SplitInfo(id: "split_0_root", direction: .right, ratio: 0.5, rect: area)
        let rightHalf = CellRect(x: 10, y: 0, width: 10, height: 10)
        let nested = SplitInfo(id: "split_1_1", direction: .down, ratio: 0.5, rect: rightHalf)
        let bottomOfRightHalf = CellRect(x: 10, y: 5, width: 10, height: 5)
        let deep = SplitInfo(id: "split_2_11", direction: .right, ratio: 0.5, rect: bottomOfRightHalf)

        let paths = CanvasGeometry.splitPaths(splits: [root, nested, deep], area: area)
        XCTAssertEqual(paths["split_0_root"], [])
        XCTAssertEqual(paths["split_1_1"], [true])
        XCTAssertEqual(paths["split_2_11"], [true, true])

        // Real geometry, built from the SAME splits and never told any id:
        // panes fill in every leaf so `paneFrames` gives independently
        // computed positions to check the polarity against.
        let leftPane = PaneRect(paneID: PaneID(rawValue: "left"), focused: false, rect: CellRect(x: 0, y: 0, width: 10, height: 10))
        let topPane = PaneRect(paneID: PaneID(rawValue: "top"), focused: false, rect: CellRect(x: 10, y: 0, width: 10, height: 5))
        let deepLeftPane = PaneRect(paneID: PaneID(rawValue: "deepLeft"), focused: false, rect: CellRect(x: 10, y: 5, width: 5, height: 5))
        let deepRightPane = PaneRect(paneID: PaneID(rawValue: "deepRight"), focused: true, rect: CellRect(x: 15, y: 5, width: 5, height: 5))
        let layout = LayoutSnapshot(
            workspaceID: WorkspaceID(rawValue: "w"), tabID: TabID(rawValue: "w:t"), zoomed: false, area: area,
            focusedPaneID: deepRightPane.paneID, panes: [leftPane, topPane, deepLeftPane, deepRightPane],
            splits: [root, nested, deep]
        )
        let canvasGrid = grid(filling: CGSize(width: 20, height: 10), scale: 1)
        let geometry = CanvasGeometry(layout: layout, grid: canvasGrid, dividerThickness: 2)

        // The divider `CanvasGeometry` itself resolves to path `[true]`
        // (its own machinery, consulting the id only through `splitPaths`'s
        // own primary source) has a `regionFrame` equal to `nested`'s own
        // rect, scaled by the SAME public `CanvasGrid.frame` production
        // code uses -- never a private re-derivation.
        let nestedHandle = try XCTUnwrap(geometry.dividers.first { $0.path == [true] })
        XCTAssertEqual(nestedHandle.regionFrame, canvasGrid.frame(for: nested.rect, area: area))

        // The independent polarity proof: `deep` is a `.right` split, so
        // its id-parsed second child (path `[true, true]`, `deepRight`)
        // must sit to the RIGHT of its first child (`deepLeft`) in the
        // real, production-computed pane frames.
        let deepLeftFrame = try XCTUnwrap(geometry.paneFrames[deepLeftPane.paneID])
        let deepRightFrame = try XCTUnwrap(geometry.paneFrames[deepRightPane.paneID])
        XCTAssertLessThan(deepLeftFrame.minX, deepRightFrame.minX, "the id-parsed second child must be the geometrically second (right-hand) region")
    }

    /// A mix of herdr-shaped and fixture-literal ids must fall back to the
    /// structural derivation entirely, not resolve the herdr-shaped ones by
    /// parsing and guess at the rest -- a partial parse gives no reason to
    /// trust the id scheme means the same thing for every split.
    func testAnyUnparseableIDFallsBackToStructuralDerivationForEverySplit() {
        let area = CellRect(x: 0, y: 0, width: 20, height: 10)
        let root = SplitInfo(id: "split_0_root", direction: .right, ratio: 0.5, rect: area)
        let rightHalf = CellRect(x: 10, y: 0, width: 10, height: 10)
        let nested = SplitInfo(id: "custom-id-not-herdr-shaped", direction: .down, ratio: 0.5, rect: rightHalf)

        let paths = CanvasGeometry.splitPaths(splits: [root, nested], area: area)

        XCTAssertEqual(paths["split_0_root"], [], "still resolved, via the structural fallback this time")
        XCTAssertEqual(paths["custom-id-not-herdr-shaped"], [true])
    }

    /// Two DIFFERENT split ids parsing to the SAME path -- unreachable
    /// against a real herdr snapshot (its own ids are unique by
    /// construction), but cheap to guard against a caller that turns paths
    /// into dictionary keys (`HerdrStore.predictedLayout`) trapping on it.
    func testDuplicatePathsFromDistinctSplitIDsDeclineThePrimarySource() {
        let area = CellRect(x: 0, y: 0, width: 20, height: 10)
        // Two different ids, both parsing to path [true].
        let root = SplitInfo(id: "split_0_root", direction: .right, ratio: 0.5, rect: area)
        let rightHalf = CellRect(x: 10, y: 0, width: 10, height: 10)
        let duplicateOne = SplitInfo(id: "split_1_1", direction: .down, ratio: 0.5, rect: rightHalf)
        let duplicateTwo = SplitInfo(id: "split_2_1", direction: .down, ratio: 0.5, rect: rightHalf)

        let paths = CanvasGeometry.splitPaths(splits: [root, duplicateOne, duplicateTwo], area: area)

        // Declined the id-parsed source entirely; fell back to the
        // structural derivation, which resolves by rect match instead and
        // so only ever assigns path [true] once.
        XCTAssertEqual(paths.values.filter { $0 == [true] }.count, 1, "the duplicate path must not survive into the result at all")
    }

    // MARK: - liveRatioOverride (a divider drag's live footprint preview)

    /// The exported-tree path derives BOTH pane frames and divider frames
    /// from the same ratio, so overriding one split's ratio there moves the
    /// panes on both sides live -- the property the divider drag's preview
    /// depends on. Never true of the rect-derivation fallback (see its own
    /// doc comment): herdr's literal pane rects cannot be recomputed from a
    /// ratio at all.
    func testLiveRatioOverrideMovesPaneFramesOnTheExportedTreePath() throws {
        let area = CellRect(x: 0, y: 0, width: 200, height: 100)
        let root = ExportedLayoutNode.split(
            direction: .right, ratio: 0.5,
            first: .pane(ExportedLayoutPane(paneID: PaneID(rawValue: "left"))),
            second: .pane(ExportedLayoutPane(paneID: PaneID(rawValue: "right")))
        )
        let grid = grid(filling: CGSize(width: 200, height: 100), scale: 1)

        let atRest = CanvasGeometry(exportedRoot: root, area: area, tabID: TabID(rawValue: "w:t"), grid: grid, dividerThickness: 6)
        let left0 = try XCTUnwrap(atRest.paneFrames[PaneID(rawValue: "left")])
        XCTAssertEqual(left0.width, 100, accuracy: 0.01)

        let overridden = CanvasGeometry(
            exportedRoot: root, area: area, tabID: TabID(rawValue: "w:t"), grid: grid, dividerThickness: 6,
            liveRatioOverride: (path: [], ratio: 0.25)
        )
        let left1 = try XCTUnwrap(overridden.paneFrames[PaneID(rawValue: "left")])
        let right1 = try XCTUnwrap(overridden.paneFrames[PaneID(rawValue: "right")])
        XCTAssertEqual(left1.width, 50, accuracy: 0.01, "the pane must follow the live ratio, not stay at its pre-drag width")
        XCTAssertEqual(right1.width, 150, accuracy: 0.01)
        XCTAssertEqual(right1.minX, 50, accuracy: 0.01)
    }

    /// An override on a NESTED split moves only that split's own two
    /// children; the sibling elsewhere in the tree, and the root split
    /// itself, must be untouched.
    func testLiveRatioOverrideOnANestedSplitLeavesTheRestOfTheTreeAlone() throws {
        let area = CellRect(x: 0, y: 0, width: 200, height: 100)
        let root = ExportedLayoutNode.split(
            direction: .right, ratio: 0.5,
            first: .pane(ExportedLayoutPane(paneID: PaneID(rawValue: "left"))),
            second: .split(
                direction: .down, ratio: 0.5,
                first: .pane(ExportedLayoutPane(paneID: PaneID(rawValue: "topRight"))),
                second: .pane(ExportedLayoutPane(paneID: PaneID(rawValue: "bottomRight")))
            )
        )
        let grid = grid(filling: CGSize(width: 200, height: 100), scale: 1)

        let overridden = CanvasGeometry(
            exportedRoot: root, area: area, tabID: TabID(rawValue: "w:t"), grid: grid, dividerThickness: 6,
            liveRatioOverride: (path: [true], ratio: 0.25)
        )

        let left = try XCTUnwrap(overridden.paneFrames[PaneID(rawValue: "left")])
        XCTAssertEqual(left.width, 100, accuracy: 0.01, "the root split is untouched by an override targeting its second child")

        let topRight = try XCTUnwrap(overridden.paneFrames[PaneID(rawValue: "topRight")])
        let bottomRight = try XCTUnwrap(overridden.paneFrames[PaneID(rawValue: "bottomRight")])
        XCTAssertEqual(topRight.height, 25, accuracy: 0.01, "0.25 of the 100-tall second-child region")
        XCTAssertEqual(bottomRight.height, 75, accuracy: 0.01)
    }

    // MARK: - The dragged split's boundary is continuous

    /// A 12-cell area on a 1200pt canvas: one herdr cell is 100pt wide, so a
    /// boundary rounded to the cell grid lands up to half a cell -- 50pt --
    /// from where the pointer is. 0.29 rounds to 3 cells (300pt); the live
    /// preview has to put it at 348.
    private func wideCellTree() -> (root: ExportedLayoutNode, area: CellRect, grid: CanvasGrid) {
        (
            .split(
                direction: .right, ratio: 0.5,
                first: .pane(ExportedLayoutPane(paneID: PaneID(rawValue: "left"))),
                second: .pane(ExportedLayoutPane(paneID: PaneID(rawValue: "right")))
            ),
            CellRect(x: 0, y: 0, width: 12, height: 4),
            grid(filling: CGSize(width: 1200, height: 400), scale: 1)
        )
    }

    func testTheDraggedSplitsBoxesFollowTheRatioRatherThanTheCellGrid() throws {
        let tree = wideCellTree()

        let geometry = CanvasGeometry(
            exportedRoot: tree.root, area: tree.area, tabID: TabID(rawValue: "w:t"), grid: tree.grid, dividerThickness: 6,
            liveRatioOverride: (path: [], ratio: 0.29)
        )

        let left = try XCTUnwrap(geometry.paneFrames[PaneID(rawValue: "left")])
        let right = try XCTUnwrap(geometry.paneFrames[PaneID(rawValue: "right")])
        XCTAssertEqual(left.width, 348, accuracy: 0.01, "0.29 of 1200pt, not the 300pt the 3-cell rounding gives")
        XCTAssertEqual(right.minX, 348, accuracy: 0.01)
        XCTAssertEqual(right.maxX, 1200, accuracy: 0.01, "the two boxes still tile the region exactly")
        XCTAssertEqual(try XCTUnwrap(geometry.dividers.first).frame.midX, 348, accuracy: 0.01)
    }

    /// Two ratios inside the SAME cell: 12 * 0.26 and 12 * 0.28 both round to
    /// 3 cells, so on the cell grid neither moves anything. The whole point of
    /// the live preview is that both move the box.
    func testASubCellRatioChangeStillMovesTheDraggedBoundary() throws {
        let tree = wideCellTree()

        func boundary(_ ratio: Double) throws -> CGFloat {
            let geometry = CanvasGeometry(
                exportedRoot: tree.root, area: tree.area, tabID: TabID(rawValue: "w:t"), grid: tree.grid, dividerThickness: 6,
                liveRatioOverride: (path: [], ratio: ratio)
            )
            return try XCTUnwrap(geometry.paneFrames[PaneID(rawValue: "left")]).width
        }

        XCTAssertEqual(try boundary(0.26), 312, accuracy: 0.01)
        XCTAssertEqual(try boundary(0.28), 336, accuracy: 0.01)
    }

    /// Only the dragged split leaves the cell grid. A ratio carried by the
    /// tree itself is still rounded to whole cells, so nothing about the
    /// at-rest layout moves.
    func testASplitThatIsNotBeingDraggedKeepsTheCellGrid() throws {
        let tree = wideCellTree()
        let root = ExportedLayoutNode.split(
            direction: .right, ratio: 0.29,
            first: .pane(ExportedLayoutPane(paneID: PaneID(rawValue: "left"))),
            second: .pane(ExportedLayoutPane(paneID: PaneID(rawValue: "right")))
        )

        let geometry = CanvasGeometry(
            exportedRoot: root, area: tree.area, tabID: TabID(rawValue: "w:t"), grid: tree.grid, dividerThickness: 6
        )

        XCTAssertEqual(try XCTUnwrap(geometry.paneFrames[PaneID(rawValue: "left")]).width, 300, accuracy: 0.01)
    }

    /// The dragged split's descendants ride the region the drag moved, so a
    /// nested split's own children fill it exactly -- and the ancestor above
    /// the dragged one keeps its cell edge.
    func testADraggedSplitCarriesItsDescendantsAndLeavesItsAncestorAlone() throws {
        let tree = wideCellTree()
        let root = ExportedLayoutNode.split(
            direction: .right, ratio: 0.29,
            first: .pane(ExportedLayoutPane(paneID: PaneID(rawValue: "left"))),
            second: .split(
                direction: .down, ratio: 0.5,
                first: .pane(ExportedLayoutPane(paneID: PaneID(rawValue: "topRight"))),
                second: .pane(ExportedLayoutPane(paneID: PaneID(rawValue: "bottomRight")))
            )
        )

        let geometry = CanvasGeometry(
            exportedRoot: root, area: tree.area, tabID: TabID(rawValue: "w:t"), grid: tree.grid, dividerThickness: 6,
            liveRatioOverride: (path: [true], ratio: 0.3)
        )

        XCTAssertEqual(
            try XCTUnwrap(geometry.paneFrames[PaneID(rawValue: "left")]).width, 300, accuracy: 0.01,
            "the root is not the dragged split, so its boundary stays on the cell grid"
        )
        let topRight = try XCTUnwrap(geometry.paneFrames[PaneID(rawValue: "topRight")])
        let bottomRight = try XCTUnwrap(geometry.paneFrames[PaneID(rawValue: "bottomRight")])
        XCTAssertEqual(topRight.height, 120, accuracy: 0.01, "0.3 of the 400pt region, not the 100pt a 1-cell rounding gives")
        XCTAssertEqual(bottomRight.minY, 120, accuracy: 0.01)
        XCTAssertEqual(topRight.minX, 300, accuracy: 0.01)
        XCTAssertEqual(topRight.width, 900, accuracy: 0.01)
    }

    /// A pane two levels under the dragged split still fills the region the
    /// drag moved: the exact rect is handed down the recursion, not
    /// recomputed from the cell map that put it back on the grid.
    func testAGrandchildOfTheDraggedSplitRidesTheMovedRegion() throws {
        let tree = wideCellTree()
        let root = ExportedLayoutNode.split(
            direction: .right, ratio: 0.5,
            first: .pane(ExportedLayoutPane(paneID: PaneID(rawValue: "left"))),
            second: .split(
                direction: .down, ratio: 0.5,
                first: .pane(ExportedLayoutPane(paneID: PaneID(rawValue: "topRight"))),
                second: .split(
                    direction: .right, ratio: 0.5,
                    first: .pane(ExportedLayoutPane(paneID: PaneID(rawValue: "bottomLeft"))),
                    second: .pane(ExportedLayoutPane(paneID: PaneID(rawValue: "bottomRight")))
                )
            )
        )

        let geometry = CanvasGeometry(
            exportedRoot: root, area: tree.area, tabID: TabID(rawValue: "w:t"), grid: tree.grid, dividerThickness: 6,
            liveRatioOverride: (path: [], ratio: 0.29)
        )

        let bottomLeft = try XCTUnwrap(geometry.paneFrames[PaneID(rawValue: "bottomLeft")])
        let bottomRight = try XCTUnwrap(geometry.paneFrames[PaneID(rawValue: "bottomRight")])
        XCTAssertEqual(bottomLeft.minX, 348, accuracy: 0.01)
        XCTAssertEqual(bottomRight.maxX, 1200, accuracy: 0.01)
        XCTAssertEqual(bottomLeft.maxX, bottomRight.minX, accuracy: 0.01, "no seam between two grandchildren")
    }

    /// The cached export lags the layout snapshot by a round trip, and a
    /// committed divider drag lands in the snapshot first (the store's
    /// prediction, then herdr's own event). The canvas must follow the
    /// snapshot's ratio, or the drag snaps back to the export's old split
    /// until the refetch arrives.
    func testResolvedGeometryTakesSplitRatiosFromTheLayoutSnapshotOverAStaleExport() throws {
        let area = CellRect(x: 0, y: 0, width: 200, height: 100)
        let left = PaneID(rawValue: "left")
        let right = PaneID(rawValue: "right")
        let tabID = TabID(rawValue: "w:t")
        let layout = LayoutSnapshot(
            workspaceID: WorkspaceID(rawValue: "w"), tabID: tabID, zoomed: false, area: area, focusedPaneID: left,
            panes: [
                PaneRect(paneID: left, focused: true, rect: CellRect(x: 0, y: 0, width: 140, height: 100)),
                PaneRect(paneID: right, focused: false, rect: CellRect(x: 140, y: 0, width: 60, height: 100)),
            ],
            splits: [SplitInfo(id: "split_0_root", direction: .right, ratio: 0.7, rect: area)]
        )
        let staleExport = ExportedLayoutDescription(
            workspaceID: WorkspaceID(rawValue: "w"), tabID: tabID, zoomed: false, focusedPaneID: left,
            root: .split(direction: .right, ratio: 0.5, first: .pane(ExportedLayoutPane(paneID: left)), second: .pane(ExportedLayoutPane(paneID: right)))
        )

        let geometry = CanvasGeometry.resolved(
            layout: layout, exported: staleExport, grid: grid(filling: CGSize(width: 200, height: 100), scale: 1), dividerThickness: 6
        )

        XCTAssertEqual(try XCTUnwrap(geometry.paneFrames[left]).width, 140, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(geometry.paneFrames[right]).minX, 140, accuracy: 0.01)
    }

    func testARightSplitDividerIsAVerticalLine() {
        let divider = DividerHandle(
            tabID: TabID(rawValue: "w:t"), path: [], frame: .zero, direction: .right, regionFrame: .zero, cellExtent: 0
        )
        XCTAssertTrue(divider.isVerticalLine)
    }

    func testADownSplitDividerIsNotAVerticalLine() {
        let divider = DividerHandle(
            tabID: TabID(rawValue: "w:t"), path: [], frame: .zero, direction: .down, regionFrame: .zero, cellExtent: 0
        )
        XCTAssertFalse(divider.isVerticalLine)
    }
}
