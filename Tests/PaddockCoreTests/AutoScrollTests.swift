import CoreGraphics
import XCTest
@testable import PaddockCore

final class AutoScrollTests: XCTestCase {
    private let rail = CGRect(x: 0, y: 26, width: 192, height: 400)
    private let strip = CGRect(x: 193, y: 26, width: 500, height: 36)

    private func railVelocity(y: CGFloat) -> CGFloat {
        AutoScroll.velocity(pointer: CGPoint(x: 90, y: y), viewport: rail, axis: .vertical)
    }

    // MARK: - velocity

    func testVelocityIsZeroFromTheBandsInnerEdgeInward() {
        XCTAssertEqual(railVelocity(y: rail.minY + AutoScroll.band), 0)
        XCTAssertEqual(railVelocity(y: rail.midY), 0)
        XCTAssertEqual(railVelocity(y: rail.maxY - AutoScroll.band), 0)
    }

    func testVelocityOnTheEdgeItselfIsTheMaximum() {
        XCTAssertEqual(railVelocity(y: rail.minY), -AutoScroll.maximumSpeed)
    }

    /// Closer is faster at every step, and never one fixed speed: the midway
    /// point runs well under half the edge speed.
    func testVelocityRampsWithProximityOnBothEdges() {
        let depths: [CGFloat] = [23, 18, 12, 6, 1, 0]
        let leading = depths.map { abs(railVelocity(y: rail.minY + $0)) }
        let trailing = depths.map { railVelocity(y: rail.maxY - 0.001 - $0) }
        XCTAssertEqual(leading, leading.sorted())
        XCTAssertEqual(Set(leading).count, leading.count, "\(leading)")
        XCTAssertEqual(trailing, trailing.sorted())
        XCTAssertEqual(Set(trailing).count, trailing.count, "\(trailing)")
        XCTAssertTrue(depths.allSatisfy { railVelocity(y: rail.minY + $0) < 0 })
        XCTAssertTrue(trailing.allSatisfy { $0 > 0 })
        XCTAssertLessThan(abs(railVelocity(y: rail.minY + AutoScroll.band / 2)), AutoScroll.maximumSpeed / 2)
    }

    func testVelocityOutsideTheViewportIsZero() {
        XCTAssertEqual(railVelocity(y: rail.minY - 1), 0)
        XCTAssertEqual(railVelocity(y: rail.maxY), 0)
        XCTAssertEqual(AutoScroll.velocity(pointer: CGPoint(x: rail.maxX + 1, y: rail.minY), viewport: rail, axis: .vertical), 0)
    }

    func testHorizontalAxisReadsXAndIgnoresHeight() {
        XCTAssertLessThan(AutoScroll.velocity(pointer: CGPoint(x: strip.minX + 2, y: strip.minY + 1), viewport: strip, axis: .horizontal), 0)
        XCTAssertGreaterThan(AutoScroll.velocity(pointer: CGPoint(x: strip.maxX - 2, y: strip.maxY - 1), viewport: strip, axis: .horizontal), 0)
        XCTAssertEqual(AutoScroll.velocity(pointer: CGPoint(x: strip.midX, y: strip.minY + 1), viewport: strip, axis: .horizontal), 0)
    }

    func testAShortViewportScrollsTowardTheNearerEdge() {
        let short = CGRect(x: 0, y: 0, width: 100, height: 30)
        XCTAssertLessThan(AutoScroll.velocity(pointer: CGPoint(x: 50, y: 10), viewport: short, axis: .vertical), 0)
        XCTAssertGreaterThan(AutoScroll.velocity(pointer: CGPoint(x: 50, y: 20), viewport: short, axis: .vertical), 0)
    }

    // MARK: - ticks

    private func railRegion(offset: CGFloat, maximumOffset: CGFloat = 500) -> AutoScroller.Region {
        AutoScroller.Region(surface: .rail, viewport: rail, axis: .vertical, offset: offset, maximumOffset: maximumOffset)
    }

    private var railTop: CGPoint { CGPoint(x: 90, y: rail.minY) }

    func testTickAdvancesByVelocityTimesElapsed() throws {
        var scroller = AutoScroller()
        let step = try XCTUnwrap(scroller.tick(pointer: railTop, regions: [railRegion(offset: 100)], elapsed: 1.0 / 60))
        XCTAssertEqual(step.surface, .rail)
        XCTAssertEqual(step.offset, 100 - AutoScroll.maximumSpeed / 60, accuracy: 0.0001)
    }

    /// The scroll view reports its offset a frame late. The second tick sees
    /// the same stale 100 and must still move on from its own last step.
    func testTickCarriesItsOwnOffsetPastAStaleReport() throws {
        var scroller = AutoScroller()
        _ = scroller.tick(pointer: railTop, regions: [railRegion(offset: 100)], elapsed: 1.0 / 60)
        let second = try XCTUnwrap(scroller.tick(pointer: railTop, regions: [railRegion(offset: 100)], elapsed: 1.0 / 60))
        XCTAssertEqual(second.offset, 100 - 2 * AutoScroll.maximumSpeed / 60, accuracy: 0.0001)
    }

    func testTickClampsAtTheLimitThenHoldsAndStopsWantingTicks() throws {
        var scroller = AutoScroller()
        let clamped = try XCTUnwrap(scroller.tick(pointer: railTop, regions: [railRegion(offset: 5)], elapsed: 1.0 / 60))
        XCTAssertEqual(clamped.offset, 0)
        XCTAssertNil(scroller.tick(pointer: railTop, regions: [railRegion(offset: 5)], elapsed: 1.0 / 60))
        XCTAssertFalse(scroller.pointerMoved(to: railTop, regions: [railRegion(offset: 0)]))

        let bottom = CGPoint(x: 90, y: rail.maxY - 1)
        var down = AutoScroller()
        let end = try XCTUnwrap(down.tick(pointer: bottom, regions: [railRegion(offset: 498, maximumOffset: 500)], elapsed: 1.0 / 30))
        XCTAssertEqual(end.offset, 500)
    }

    func testTickStopsTheMomentThePointerLeavesTheBandAndForgetsItsOffset() throws {
        var scroller = AutoScroller()
        _ = scroller.tick(pointer: railTop, regions: [railRegion(offset: 100)], elapsed: 1.0 / 60)
        XCTAssertNil(scroller.tick(pointer: CGPoint(x: 90, y: rail.minY + AutoScroll.band), regions: [railRegion(offset: 100)], elapsed: 1.0 / 60))
        let fresh = try XCTUnwrap(scroller.tick(pointer: railTop, regions: [railRegion(offset: 300)], elapsed: 1.0 / 60))
        XCTAssertEqual(fresh.offset, 300 - AutoScroll.maximumSpeed / 60, accuracy: 0.0001)
    }

    func testAStalledTickAdvancesByAtMostOneStep() throws {
        var scroller = AutoScroller()
        let step = try XCTUnwrap(scroller.tick(pointer: railTop, regions: [railRegion(offset: 400)], elapsed: 2))
        XCTAssertEqual(step.offset, 400 - AutoScroll.maximumSpeed * CGFloat(AutoScroll.maximumStep), accuracy: 0.0001)
    }

    func testContentThatFitsNeverScrolls() {
        var scroller = AutoScroller()
        let fits = railRegion(offset: 0, maximumOffset: 0)
        XCTAssertFalse(scroller.pointerMoved(to: CGPoint(x: 90, y: rail.maxY - 1), regions: [fits]))
        XCTAssertNil(scroller.tick(pointer: CGPoint(x: 90, y: rail.maxY - 1), regions: [fits], elapsed: 1.0 / 60))
    }

    func testOnlyTheHoveredSurfaceScrolls() throws {
        var scroller = AutoScroller()
        let stripRegion = AutoScroller.Region(surface: .strip, viewport: strip, axis: .horizontal, offset: 50, maximumOffset: 300)
        let step = try XCTUnwrap(scroller.tick(pointer: CGPoint(x: strip.maxX - 1, y: strip.midY), regions: [railRegion(offset: 100), stripRegion], elapsed: 1.0 / 60))
        XCTAssertEqual(step.surface, .strip)
        XCTAssertGreaterThan(step.offset, 50)
    }

    func testASpringLoadHoldsTheBandStillUntilThePointerLeavesIt() throws {
        var scroller = AutoScroller()
        let regions = [railRegion(offset: 100)]
        XCTAssertTrue(scroller.pointerMoved(to: railTop, regions: regions))
        scroller.springLoaded(pointer: railTop, regions: regions)

        XCTAssertNil(scroller.tick(pointer: railTop, regions: regions, elapsed: 1.0 / 60))
        XCTAssertFalse(scroller.pointerMoved(to: CGPoint(x: 90, y: rail.minY + 3), regions: regions))

        XCTAssertFalse(scroller.pointerMoved(to: CGPoint(x: 90, y: rail.midY), regions: regions))
        XCTAssertTrue(scroller.pointerMoved(to: railTop, regions: regions))
        XCTAssertNotNil(scroller.tick(pointer: railTop, regions: regions, elapsed: 1.0 / 60))
    }

    func testResetForgetsBothTheCarriedOffsetAndASuppression() throws {
        var scroller = AutoScroller()
        let regions = [railRegion(offset: 100)]
        _ = scroller.tick(pointer: railTop, regions: regions, elapsed: 1.0 / 60)
        scroller.springLoaded(pointer: railTop, regions: regions)
        scroller.reset()
        let step = try XCTUnwrap(scroller.tick(pointer: railTop, regions: [railRegion(offset: 200)], elapsed: 1.0 / 60))
        XCTAssertEqual(step.offset, 200 - AutoScroll.maximumSpeed / 60, accuracy: 0.0001)
    }
}
