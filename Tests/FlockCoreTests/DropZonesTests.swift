import XCTest
import CoreGraphics
@testable import FlockCore

final class DropZonesTests: XCTestCase {
    private let strip = CGRect(x: 0, y: 0, width: 600, height: 42)
    private let rail = CGRect(x: 0, y: 0, width: 216, height: 700)

    func testNewTabZoneFillsTheStripsFreeRunInsideItsMargin() throws {
        let zone = try XCTUnwrap(DropZones.trailing(in: strip, itemsEndingAt: 332, before: 500))
        let m = DropZones.margin
        XCTAssertEqual(zone, CGRect(x: 332 + m, y: m / 2, width: 168 - 2 * m, height: 42 - m))
    }

    /// The margin is the whole point of the zone not touching its neighbours,
    /// so it has to be real on every side.
    func testEveryZoneEdgeClearsWhatItBorders() throws {
        let zone = try XCTUnwrap(DropZones.trailing(in: strip, itemsEndingAt: 332, before: 500))
        XCTAssertGreaterThan(zone.minX, 332)
        XCTAssertLessThan(zone.maxX, 500)
        XCTAssertGreaterThan(zone.minY, strip.minY)
        XCTAssertLessThan(zone.maxY, strip.maxY)
    }

    func testNewTabZoneVanishesWhenTheStripIsFull() {
        XCTAssertNil(DropZones.trailing(in: strip, itemsEndingAt: 470, before: 500))
    }

    func testNewTabZoneStartsAtTheStripsOwnEdgeWithNoTabs() throws {
        let zone = try XCTUnwrap(DropZones.trailing(in: strip, itemsEndingAt: nil, before: 500))
        XCTAssertEqual(zone.minX, strip.minX + DropZones.margin)
        XCTAssertEqual(zone.maxX, 500 - DropZones.margin)
    }

    func testNewTabZoneNeverReachesPastTheStrip() throws {
        let zone = try XCTUnwrap(DropZones.trailing(in: strip, itemsEndingAt: 100, before: 900))
        XCTAssertEqual(zone.maxX, strip.maxX - DropZones.margin)
    }

    func testNewWorkspaceZoneFillsTheRailBelowTheLastRow() throws {
        let zone = try XCTUnwrap(DropZones.below(in: rail, itemsEndingAt: 134))
        let m = DropZones.margin
        XCTAssertEqual(zone, CGRect(x: m / 2, y: 134 + m, width: 216 - m, height: 566 - 2 * m))
    }

    func testNewWorkspaceZoneVanishesWhenTheRailIsFull() {
        XCTAssertNil(DropZones.below(in: rail, itemsEndingAt: 680))
    }
}
