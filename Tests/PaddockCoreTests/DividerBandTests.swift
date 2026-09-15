import XCTest
import CoreGraphics
@testable import PaddockCore

final class DividerBandTests: XCTestCase {
    private func makeDivider(path: [Bool], frame: CGRect, direction: SplitDirection) -> DividerHandle {
        DividerHandle(tabID: TabID(rawValue: "t"), path: path, frame: frame, direction: direction, regionFrame: frame, cellExtent: 100)
    }

    // MARK: - hitBand

    func testHitBandWidensAVerticalDividerSymmetricallyAroundItsBoundary() {
        let divider = makeDivider(path: [], frame: CGRect(x: 97, y: 10, width: 6, height: 80), direction: .right)
        let band = divider.hitBand(thickness: 16)

        XCTAssertEqual(band.width, 16)
        XCTAssertEqual(band.midX, divider.frame.midX)
        XCTAssertEqual(band.origin.y, divider.frame.origin.y)
        XCTAssertEqual(band.height, divider.frame.height)
    }

    func testHitBandWidensAHorizontalDividerSymmetricallyAroundItsBoundary() {
        let divider = makeDivider(path: [true], frame: CGRect(x: 10, y: 47, width: 80, height: 6), direction: .down)
        let band = divider.hitBand(thickness: 16)

        XCTAssertEqual(band.height, 16)
        XCTAssertEqual(band.midY, divider.frame.midY)
        XCTAssertEqual(band.origin.x, divider.frame.origin.x)
        XCTAssertEqual(band.width, divider.frame.width)
    }

    /// `PaneCellView`'s real chrome, mirrored here rather than imported: 10pt
    /// leading/trailing content inset, 8pt bottom inset, 8pt legend half-height
    /// plus 12pt top inset above a pane's terminal surface, and the gutter's
    /// own half-inset each pane box already carries. If any of these numbers
    /// change, this must be rechecked before trusting the band stays off the
    /// terminal surface.
    func testHitBandNeverReachesEitherNeighborsTerminalSurface() {
        let halfGutter: CGFloat = DividerBand.gutter / 2
        let leadingInset: CGFloat = 10
        let bottomInset: CGFloat = 8
        let legendHalfHeight: CGFloat = 8
        let topInset: CGFloat = 12

        let verticalMargin = halfGutter + leadingInset
        let aboveMargin = halfGutter + bottomInset
        let belowMargin = halfGutter + legendHalfHeight + topInset
        let bandHalf = DividerBand.thickness / 2

        XCTAssertLessThan(bandHalf, verticalMargin)
        XCTAssertLessThan(bandHalf, aboveMargin)
        XCTAssertLessThan(bandHalf, belowMargin)
    }

    // MARK: - intersections

    /// A root vertical divider spanning the full canvas height (boundary
    /// x=100) and a nested horizontal divider in the right column (boundary
    /// y=40, spanning x 100...200) -- the T-junction shape a real 3-pane
    /// layout produces (see `CanvasGeometryTests.threePaneLayout`).
    private func tJunction() -> (vertical: DividerHandle, horizontal: DividerHandle) {
        let vertical = makeDivider(path: [], frame: CGRect(x: 97, y: 0, width: 6, height: 100), direction: .right)
        let horizontal = makeDivider(path: [true], frame: CGRect(x: 100, y: 37, width: 100, height: 6), direction: .down)
        return (vertical, horizontal)
    }

    func testIntersectionFoundAtATJunctionWithTheOverlapSquare() throws {
        let (vertical, horizontal) = tJunction()
        let found = DividerIntersections.find(in: [vertical, horizontal], bandThickness: 16)

        let intersection = try XCTUnwrap(found.first)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(intersection.vertical.path, [])
        XCTAssertEqual(intersection.horizontal.path, [true])
        // Only the half of the vertical band on the horizontal divider's own
        // side of the boundary overlaps; the horizontal band's full height
        // sits entirely within the vertical band's (which spans the whole
        // canvas height).
        XCTAssertEqual(intersection.square, CGRect(x: 100, y: 32, width: 8, height: 16))
    }

    func testNoIntersectionWhenBandsDoNotOverlap() {
        let vertical = makeDivider(path: [], frame: CGRect(x: 97, y: 0, width: 6, height: 100), direction: .right)
        let farHorizontal = makeDivider(path: [true], frame: CGRect(x: 300, y: 37, width: 100, height: 6), direction: .down)
        XCTAssertTrue(DividerIntersections.find(in: [vertical, farHorizontal], bandThickness: 16).isEmpty)
    }

    func testNoIntersectionAmongOnlyVerticalOrOnlyHorizontalDividers() {
        let a = makeDivider(path: [false], frame: CGRect(x: 47, y: 0, width: 6, height: 100), direction: .right)
        let b = makeDivider(path: [true], frame: CGRect(x: 97, y: 0, width: 6, height: 100), direction: .right)
        XCTAssertTrue(DividerIntersections.find(in: [a, b], bandThickness: 16).isEmpty)
    }

    func testResolvePicksTheDividerWithTheNearerCenterline() throws {
        let (vertical, horizontal) = tJunction()
        let found = DividerIntersections.find(in: [vertical, horizontal], bandThickness: 16)
        let intersection = try XCTUnwrap(found.first)

        // Dead center: equidistant, resolves to the vertical divider.
        XCTAssertEqual(DividerIntersections.resolve(intersection, at: CGPoint(x: 100, y: 40)).path, [])
        // Along the vertical's own centerline, offset toward the horizontal:
        // still nearer the vertical line (distance 0 vs 8).
        XCTAssertEqual(DividerIntersections.resolve(intersection, at: CGPoint(x: 100, y: 48)).path, [])
        // Along the horizontal's own centerline, offset toward the vertical's
        // far edge: nearer the horizontal line (distance 0 vs 8).
        XCTAssertEqual(DividerIntersections.resolve(intersection, at: CGPoint(x: 108, y: 40)).path, [true])
        // Off both centerlines but closer to the horizontal (4 vs 5).
        XCTAssertEqual(DividerIntersections.resolve(intersection, at: CGPoint(x: 105, y: 36)).path, [true])
        // Off both centerlines but closer to the vertical (2 vs 4).
        XCTAssertEqual(DividerIntersections.resolve(intersection, at: CGPoint(x: 102, y: 44)).path, [])
    }
    // MARK: - handle

    func testHandleIsAFifthOfALongDivider() {
        XCTAssertEqual(DividerBand.handleLength(forDividerLength: 600), 120, accuracy: 0.001)
    }

    func testHandleNeverShrinksBelowItsMinimum() {
        XCTAssertEqual(DividerBand.handleLength(forDividerLength: 80), DividerBand.handleMinimumLength)
    }

    func testHandleNeverOutgrowsItsDivider() {
        XCTAssertEqual(DividerBand.handleLength(forDividerLength: 20), 20)
    }

}
