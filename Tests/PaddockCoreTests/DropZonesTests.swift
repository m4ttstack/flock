import XCTest
import CoreGraphics
@testable import PaddockCore

final class DropZonesTests: XCTestCase {
    private let strip = CGRect(x: 0, y: 0, width: 600, height: 42)
    private let rail = CGRect(x: 0, y: 0, width: 216, height: 700)

    func testNewTabZoneFillsTheStripsFreeRun() throws {
        let zone = try XCTUnwrap(DropZones.trailing(in: strip, itemsEndingAt: 332, before: 500))
        XCTAssertEqual(zone, CGRect(x: 332, y: 0, width: 168, height: 42))
    }

    func testNewTabZoneVanishesWhenTheStripIsFull() {
        XCTAssertNil(DropZones.trailing(in: strip, itemsEndingAt: 470, before: 500))
    }

    func testNewTabZoneStartsAtTheStripsOwnEdgeWithNoTabs() throws {
        let zone = try XCTUnwrap(DropZones.trailing(in: strip, itemsEndingAt: nil, before: 500))
        XCTAssertEqual(zone.minX, strip.minX)
        XCTAssertEqual(zone.maxX, 500)
    }

    func testNewTabZoneNeverReachesPastTheStrip() throws {
        let zone = try XCTUnwrap(DropZones.trailing(in: strip, itemsEndingAt: 100, before: 900))
        XCTAssertEqual(zone.maxX, strip.maxX)
    }

    func testNewWorkspaceZoneFillsTheRailBelowTheLastRow() throws {
        let zone = try XCTUnwrap(DropZones.below(in: rail, itemsEndingAt: 134))
        XCTAssertEqual(zone, CGRect(x: 0, y: 134, width: 216, height: 566))
    }

    func testNewWorkspaceZoneVanishesWhenTheRailIsFull() {
        XCTAssertNil(DropZones.below(in: rail, itemsEndingAt: 680))
    }
}
