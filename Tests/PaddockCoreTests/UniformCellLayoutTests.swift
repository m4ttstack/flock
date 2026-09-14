import XCTest
import CoreGraphics
@testable import PaddockCore

/// The uniform-cell fit: one font size for every pane, chosen so herdr's
/// whole cell grid (plus each pane's chrome) fits the canvas, with the grid
/// letterboxed inside it.
final class UniformCellLayoutTests: XCTestCase {
    /// A stand-in for Menlo at 2x: width 0.6 em, height 1.2 em, rounded to
    /// whole pixels the way ghostty rounds its cell, then back to points.
    private func metrics(_ fontSize: Double) -> CGSize {
        let px = fontSize * 2
        return CGSize(width: (px * 0.6).rounded() / 2, height: (px * 1.2).rounded() / 2)
    }

    private let chrome = PaneChrome(horizontal: 26, vertical: 34)

    private func fit(
        area: CellRect = CellRect(x: 0, y: 0, width: 120, height: 40),
        panes: [CellRect]? = nil,
        canvas: CGSize,
        maxFontSize: Double = 13
    ) -> UniformCellFit {
        UniformCellLayout.fit(
            area: area,
            panes: panes ?? [
                CellRect(x: 0, y: 0, width: 30, height: 40),
                CellRect(x: 30, y: 0, width: 30, height: 40),
                CellRect(x: 60, y: 0, width: 60, height: 40),
            ],
            canvas: canvas,
            chrome: chrome,
            maxFontSize: maxFontSize,
            cellMetrics: metrics
        )
    }

    func testSettingIsTheMaximumWhenTheCanvasIsRoomy() {
        let fit = fit(canvas: CGSize(width: 4000, height: 3000))

        XCTAssertEqual(fit.fontSize, 13)
        XCTAssertEqual(fit.surfaceCell, metrics(13))
    }

    func testBoxCellIsTheSurfaceCellPlusTheSmallestPanesChromeShare() {
        let fit = fit(canvas: CGSize(width: 4000, height: 3000))

        // Smallest pane is 30 wide and 40 tall: each of its cells carries
        // 26/30 of horizontal chrome and 34/40 of vertical chrome.
        XCTAssertEqual(fit.boxCell.width, metrics(13).width + 26.0 / 30.0, accuracy: 1e-9)
        XCTAssertEqual(fit.boxCell.height, metrics(13).height + 34.0 / 40.0, accuracy: 1e-9)
    }

    func testEveryPaneBoxHoldsItsSurfacePlusChrome() {
        let fit = fit(canvas: CGSize(width: 4000, height: 3000))
        let area = CellRect(x: 0, y: 0, width: 120, height: 40)

        for rect in [CellRect(x: 0, y: 0, width: 30, height: 40), CellRect(x: 60, y: 0, width: 60, height: 40)] {
            let box = fit.boxFrame(for: rect, area: area)
            let surface = fit.surfaceSize(cols: rect.width, rows: rect.height)
            XCTAssertGreaterThanOrEqual(box.width - chrome.horizontal + 1e-9, surface.width)
            XCTAssertGreaterThanOrEqual(box.height - chrome.vertical + 1e-9, surface.height)
        }
    }

    func testShrinksToTheLargestHalfPointSizeThatFits() {
        // At 13pt the grid needs 120 * (8 + 26/30) = 1064 wide; a 900 wide
        // canvas forces a smaller size. 12pt and 11.5pt both round to a 7pt
        // cell (120 * 7.8667 = 944, too wide); 11pt gives 6.5pt cells and
        // 120 * 7.3667 = 884 fits.
        let fit = fit(canvas: CGSize(width: 900, height: 3000))

        XCTAssertEqual(fit.fontSize, 11)
        XCTAssertEqual(fit.surfaceCell, metrics(11))
    }

    func testNeverExceedsTheSettingEvenWithRoomToSpare() {
        let fit = fit(canvas: CGSize(width: 4000, height: 3000), maxFontSize: 11)

        XCTAssertEqual(fit.fontSize, 11)
    }

    func testFloorsAtTheMinimumFontSizeWhenNothingFits() {
        let fit = fit(canvas: CGSize(width: 100, height: 50))

        XCTAssertEqual(fit.fontSize, UniformCellLayout.minimumFontSize)
    }

    func testGridIsCenteredInTheCanvas() {
        let canvas = CGSize(width: 4000, height: 3000)
        let fit = fit(canvas: canvas)
        let area = CellRect(x: 0, y: 0, width: 120, height: 40)

        let gridWidth = CGFloat(area.width) * fit.boxCell.width
        let gridHeight = CGFloat(area.height) * fit.boxCell.height
        XCTAssertEqual(fit.origin.x, (canvas.width - gridWidth) / 2, accuracy: 1e-9)
        XCTAssertEqual(fit.origin.y, (canvas.height - gridHeight) / 2, accuracy: 1e-9)
    }

    func testOverflowingGridClampsItsOriginToZero() {
        let fit = fit(canvas: CGSize(width: 100, height: 50))

        XCTAssertEqual(fit.origin, .zero)
    }

    func testPaneFramesAreExactCellMultiplesFromTheGridOrigin() {
        let fit = fit(canvas: CGSize(width: 4000, height: 3000))
        let area = CellRect(x: 0, y: 0, width: 120, height: 40)
        let rect = CellRect(x: 30, y: 0, width: 30, height: 40)

        let frame = fit.boxFrame(for: rect, area: area)
        XCTAssertEqual(frame.origin.x, fit.origin.x + 30 * fit.boxCell.width, accuracy: 1e-9)
        XCTAssertEqual(frame.origin.y, fit.origin.y, accuracy: 1e-9)
        XCTAssertEqual(frame.width, 30 * fit.boxCell.width, accuracy: 1e-9)
        XCTAssertEqual(frame.height, 40 * fit.boxCell.height, accuracy: 1e-9)
    }

    func testSurfaceSizeIsExactlyColsByRowsSurfaceCells() {
        let fit = fit(canvas: CGSize(width: 4000, height: 3000))

        let size = fit.surfaceSize(cols: 60, rows: 40)
        XCTAssertEqual(size.width, 60 * metrics(13).width, accuracy: 1e-9)
        XCTAssertEqual(size.height, 40 * metrics(13).height, accuracy: 1e-9)
    }

    func testEmptyPaneListFallsBackToTheAreaForTheChromeShare() {
        let area = CellRect(x: 0, y: 0, width: 120, height: 40)
        let fit = fit(area: area, panes: [], canvas: CGSize(width: 4000, height: 3000))

        XCTAssertEqual(fit.boxCell.width, metrics(13).width + 26.0 / 120.0, accuracy: 1e-9)
        XCTAssertEqual(fit.boxCell.height, metrics(13).height + 34.0 / 40.0, accuracy: 1e-9)
    }

    func testDegenerateAreaYieldsAZeroGrid() {
        let fit = fit(area: CellRect(x: 0, y: 0, width: 0, height: 0), panes: [], canvas: CGSize(width: 400, height: 200))

        XCTAssertEqual(fit.boxFrame(for: CellRect(x: 0, y: 0, width: 0, height: 0), area: CellRect(x: 0, y: 0, width: 0, height: 0)), .zero)
        XCTAssertEqual(fit.surfaceSize(cols: 0, rows: 0), .zero)
    }

    func testCanvasGeometryPlacesPanesOnTheFitsGrid() throws {
        let canvas = CGSize(width: 4000, height: 3000)
        let fit = fit(canvas: canvas)
        let area = CellRect(x: 0, y: 0, width: 120, height: 40)
        let panes = [
            PaneRect(paneID: PaneID(rawValue: "a"), focused: true, rect: CellRect(x: 0, y: 0, width: 30, height: 40)),
            PaneRect(paneID: PaneID(rawValue: "b"), focused: false, rect: CellRect(x: 30, y: 0, width: 30, height: 40)),
            PaneRect(paneID: PaneID(rawValue: "c"), focused: false, rect: CellRect(x: 60, y: 0, width: 60, height: 40)),
        ]
        let layout = LayoutSnapshot(
            workspaceID: WorkspaceID(rawValue: "w"), tabID: TabID(rawValue: "w:t"), zoomed: false,
            area: area, focusedPaneID: panes[0].paneID, panes: panes,
            splits: [
                SplitInfo(id: "root", direction: .right, ratio: 0.5, rect: area),
                SplitInfo(id: "left", direction: .right, ratio: 0.5, rect: CellRect(x: 0, y: 0, width: 60, height: 40)),
            ]
        )

        let geometry = CanvasGeometry.resolved(layout: layout, exported: nil, grid: fit.grid)

        for pane in panes {
            let frame = try XCTUnwrap(geometry.paneFrames[pane.paneID])
            XCTAssertEqual(frame, fit.boxFrame(for: pane.rect, area: area))
        }
        let root = try XCTUnwrap(geometry.dividers.first { $0.path == [] })
        XCTAssertEqual(root.frame.midX, fit.origin.x + 60 * fit.boxCell.width, accuracy: 1e-6)
    }
}
