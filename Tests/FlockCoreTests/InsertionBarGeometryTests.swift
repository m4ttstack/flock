import XCTest
import CoreGraphics
@testable import FlockCore

final class InsertionBarGeometryTests: XCTestCase {
    /// Three tabs, 100 wide with a 10pt gap between them, inside a strip with
    /// room above and below them.
    private let strip = CGRect(x: 0, y: 0, width: 600, height: 42)
    private var tabs: [CGRect] {
        [
            CGRect(x: 12, y: 7, width: 100, height: 28),
            CGRect(x: 122, y: 7, width: 100, height: 28),
            CGRect(x: 232, y: 7, width: 100, height: 28)
        ]
    }

    private let rail = CGRect(x: 0, y: 0, width: 216, height: 700)
    private var rows: [CGRect] {
        [
            CGRect(x: 8, y: 40, width: 200, height: 30),
            CGRect(x: 8, y: 72, width: 200, height: 30),
            CGRect(x: 8, y: 104, width: 200, height: 30)
        ]
    }

    func testBarSitsInTheGapBetweenTwoTabs() {
        let bar = InsertionBarGeometry.bar(atInsertIndex: 1, items: tabs, container: strip, axis: .vertical)
        XCTAssertEqual(bar.midX, 117, accuracy: 0.001)
        XCTAssertEqual(bar.width, InsertionBarGeometry.thickness)
    }

    func testBarSitsBeforeTheFirstTabForIndexZero() {
        let bar = InsertionBarGeometry.bar(atInsertIndex: 0, items: tabs, container: strip, axis: .vertical)
        XCTAssertEqual(bar.midX, 7, accuracy: 0.001)
    }

    func testBarSitsAfterTheLastTabForTheEndIndex() {
        let bar = InsertionBarGeometry.bar(atInsertIndex: 3, items: tabs, container: strip, axis: .vertical)
        XCTAssertEqual(bar.midX, 337, accuracy: 0.001)
    }

    func testBarSpansTheTabsCrossExtentNotTheWholeStrip() {
        let bar = InsertionBarGeometry.bar(atInsertIndex: 1, items: tabs, container: strip, axis: .vertical)
        // The overhang reaches y 3, but the leading end stays half a dot
        // inside the strip.
        XCTAssertEqual(bar.minY, 5, accuracy: 0.001)
        XCTAssertEqual(bar.maxY, 39, accuracy: 0.001)
    }

    /// The empty-strip case the explicit `stripFrame` exists for: with no
    /// items to measure against, the bar still lands inside the strip.
    func testBarFallsBackIntoAnEmptyStrip() {
        let bar = InsertionBarGeometry.bar(atInsertIndex: 0, items: [], container: strip, axis: .vertical)
        XCTAssertEqual(bar.midX, 10, accuracy: 0.001)
        XCTAssertTrue(strip.insetBy(dx: -1, dy: -1).contains(bar))
    }

    func testBarIsClampedInsideTheContainer() {
        let tight = CGRect(x: 100, y: 0, width: 200, height: 42)
        let items = [CGRect(x: 100, y: 7, width: 60, height: 28)]
        let bar = InsertionBarGeometry.bar(atInsertIndex: 0, items: items, container: tight, axis: .vertical)
        XCTAssertGreaterThanOrEqual(bar.minX, tight.minX)
    }

    /// The other half of the clamp: an item that ends flush with the
    /// container leaves no room for the end gap the bar would otherwise sit
    /// in.
    func testBarIsClampedAtTheTrailingEdgeToo() {
        let tight = CGRect(x: 0, y: 0, width: 200, height: 42)
        let items = [CGRect(x: 100, y: 7, width: 100, height: 28)]
        let bar = InsertionBarGeometry.bar(atInsertIndex: 1, items: items, container: tight, axis: .vertical)
        XCTAssertEqual(bar.midX, tight.maxX - InsertionBarGeometry.thickness / 2, accuracy: 0.001)
        XCTAssertLessThanOrEqual(bar.maxX, tight.maxX)
    }

    /// Gaps of 30 then 10: the end gaps take the SMALLEST measured gap, not
    /// the first one and not an average, so a strip with one wide gap does not
    /// push the leading bar clear off the first tab.
    func testEndGapsUseTheSmallestMeasuredGap() {
        let uneven = [
            CGRect(x: 12, y: 7, width: 100, height: 28),
            CGRect(x: 142, y: 7, width: 100, height: 28),
            CGRect(x: 252, y: 7, width: 100, height: 28)
        ]
        XCTAssertEqual(
            InsertionBarGeometry.bar(atInsertIndex: 0, items: uneven, container: strip, axis: .vertical).midX, 7, accuracy: 0.001
        )
        XCTAssertEqual(
            InsertionBarGeometry.bar(atInsertIndex: 3, items: uneven, container: strip, axis: .vertical).midX, 357, accuracy: 0.001
        )
        // The gap the index actually names is still its own midpoint.
        XCTAssertEqual(
            InsertionBarGeometry.bar(atInsertIndex: 2, items: uneven, container: strip, axis: .vertical).midX, 247, accuracy: 0.001
        )
    }

    func testRailBarIsHorizontalAndSitsBetweenTwoRows() {
        let bar = InsertionBarGeometry.bar(atInsertIndex: 2, items: rows, container: rail, axis: .horizontal)
        XCTAssertEqual(bar.midY, 103, accuracy: 0.001)
        XCTAssertEqual(bar.height, InsertionBarGeometry.thickness)
        XCTAssertEqual(bar.minX, 5, accuracy: 0.001)
        XCTAssertEqual(bar.maxX, 212, accuracy: 0.001)
    }

    func testEndDotCapsTheBarsLeadingEnd() {
        let bar = InsertionBarGeometry.bar(atInsertIndex: 1, items: tabs, container: strip, axis: .vertical)
        let dot = InsertionBarGeometry.endDot(for: bar, axis: .vertical)
        XCTAssertEqual(dot.width, InsertionBarGeometry.dotDiameter)
        XCTAssertEqual(dot.midX, bar.midX, accuracy: 0.001)
        XCTAssertEqual(dot.midY, bar.minY, accuracy: 0.001)
    }

    /// Tabs flush with the bottom of a strip that has a title bar just above
    /// it: the bar must not cross the strip's bottom edge, and its end dot
    /// must not rise above the strip's top.
    func testBarAndDotStayInsideAStripWhoseTabsSitFlushOnItsEdge() {
        let tightStrip = CGRect(x: 193, y: 26, width: 707, height: 36)
        let flushTabs = [
            CGRect(x: 203, y: 34, width: 100, height: 28),
            CGRect(x: 306, y: 34, width: 100, height: 28)
        ]
        let bar = InsertionBarGeometry.bar(atInsertIndex: 1, items: flushTabs, container: tightStrip, axis: .vertical)
        let dot = InsertionBarGeometry.endDot(for: bar, axis: .vertical)
        XCTAssertEqual(bar.maxY, tightStrip.maxY, accuracy: 0.001)
        XCTAssertEqual(dot.minY, tightStrip.minY, accuracy: 0.001)
        XCTAssertTrue(tightStrip.contains(bar))
        XCTAssertTrue(tightStrip.contains(dot))
    }

    func testEndDotCapsTheRailBarsLeftEnd() {
        let bar = InsertionBarGeometry.bar(atInsertIndex: 1, items: rows, container: rail, axis: .horizontal)
        let dot = InsertionBarGeometry.endDot(for: bar, axis: .horizontal)
        XCTAssertEqual(dot.midX, bar.minX, accuracy: 0.001)
        XCTAssertEqual(dot.midY, bar.midY, accuracy: 0.001)
    }
}
