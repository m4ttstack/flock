import XCTest
import CoreGraphics
@testable import PaddockCore

final class InsertionBarGeometryTests: XCTestCase {
    /// Three pills, 100 wide with a 10pt gap between them, inside a 42pt strip.
    private let strip = CGRect(x: 0, y: 0, width: 600, height: 42)
    private var pills: [CGRect] {
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

    func testBarSitsInTheGapBetweenTwoPills() {
        let bar = InsertionBarGeometry.bar(atInsertIndex: 1, items: pills, container: strip, axis: .vertical)
        XCTAssertEqual(bar.midX, 117, accuracy: 0.001)
        XCTAssertEqual(bar.width, InsertionBarGeometry.thickness)
    }

    func testBarSitsBeforeTheFirstPillForIndexZero() {
        let bar = InsertionBarGeometry.bar(atInsertIndex: 0, items: pills, container: strip, axis: .vertical)
        XCTAssertEqual(bar.midX, 7, accuracy: 0.001)
    }

    func testBarSitsAfterTheLastPillForTheEndIndex() {
        let bar = InsertionBarGeometry.bar(atInsertIndex: 3, items: pills, container: strip, axis: .vertical)
        XCTAssertEqual(bar.midX, 337, accuracy: 0.001)
    }

    func testBarSpansThePillsCrossExtentNotTheWholeStrip() {
        let bar = InsertionBarGeometry.bar(atInsertIndex: 1, items: pills, container: strip, axis: .vertical)
        XCTAssertEqual(bar.minY, 4, accuracy: 0.001)
        XCTAssertEqual(bar.maxY, 38, accuracy: 0.001)
    }

    /// The empty-strip case the explicit `stripFrame` exists for: with no
    /// items to measure against, the bar still lands inside the strip.
    func testBarFallsBackIntoAnEmptyStrip() {
        let bar = InsertionBarGeometry.bar(atInsertIndex: 0, items: [], container: strip, axis: .vertical)
        XCTAssertEqual(bar.midX, 8, accuracy: 0.001)
        XCTAssertTrue(strip.insetBy(dx: -1, dy: -1).contains(bar))
    }

    func testBarIsClampedInsideTheContainer() {
        let tight = CGRect(x: 100, y: 0, width: 200, height: 42)
        let items = [CGRect(x: 100, y: 7, width: 60, height: 28)]
        let bar = InsertionBarGeometry.bar(atInsertIndex: 0, items: items, container: tight, axis: .vertical)
        XCTAssertGreaterThanOrEqual(bar.minX, tight.minX)
    }

    func testRailBarIsHorizontalAndSitsBetweenTwoRows() {
        let bar = InsertionBarGeometry.bar(atInsertIndex: 2, items: rows, container: rail, axis: .horizontal)
        XCTAssertEqual(bar.midY, 103, accuracy: 0.001)
        XCTAssertEqual(bar.height, InsertionBarGeometry.thickness)
        XCTAssertEqual(bar.minX, 5, accuracy: 0.001)
        XCTAssertEqual(bar.maxX, 211, accuracy: 0.001)
    }

    func testEndDotCapsTheBarsLeadingEnd() {
        let bar = InsertionBarGeometry.bar(atInsertIndex: 1, items: pills, container: strip, axis: .vertical)
        let dot = InsertionBarGeometry.endDot(for: bar, axis: .vertical)
        XCTAssertEqual(dot.width, InsertionBarGeometry.dotDiameter)
        XCTAssertEqual(dot.midX, bar.midX, accuracy: 0.001)
        XCTAssertEqual(dot.midY, bar.minY, accuracy: 0.001)
    }

    func testEndDotCapsTheRailBarsLeftEnd() {
        let bar = InsertionBarGeometry.bar(atInsertIndex: 1, items: rows, container: rail, axis: .horizontal)
        let dot = InsertionBarGeometry.endDot(for: bar, axis: .horizontal)
        XCTAssertEqual(dot.midX, bar.minX, accuracy: 0.001)
        XCTAssertEqual(dot.midY, bar.midY, accuracy: 0.001)
    }
}
