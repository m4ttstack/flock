import XCTest
@testable import FlockCore

final class TileTailPolicyTests: XCTestCase {
    func testASmallBoxKeepsTheStatusWord() {
        XCTAssertEqual(TileDetail.of(box: CGSize(width: 80, height: 60)), .status)
        XCTAssertEqual(TileDetail.of(box: CGSize(width: 200, height: 30)), .status)
    }

    func testEachLevelNeedsBothItsWidthAndItsHeight() {
        XCTAssertEqual(TileDetail.of(box: CGSize(width: 110, height: 50)), .tail)
        XCTAssertEqual(TileDetail.of(box: CGSize(width: 120, height: 200)), .tail, "too narrow for the meta line")
        XCTAssertEqual(TileDetail.of(box: CGSize(width: 200, height: 80)), .meta)
        XCTAssertEqual(TileDetail.of(box: CGSize(width: 200, height: 140)), .timeline)
    }

    func testDetailOnlyGrowsWithTheBox() {
        var last = TileDetail.status
        for side in stride(from: 20.0, through: 400, by: 10) {
            let detail = TileDetail.of(box: CGSize(width: side * 1.6, height: side))
            XCTAssertGreaterThanOrEqual(detail, last)
            last = detail
        }
        XCTAssertEqual(last, .timeline)
    }

    func testTheGridReadsAThirdAsOftenAsAZoomedIsland() {
        XCTAssertEqual(TileTailCadence.grid, .seconds(3))
        XCTAssertEqual(TileTailCadence.zoomed, .seconds(1))
    }

    func testOffsetsStayInsideTheIntervalAndSpreadAcrossIt() {
        let panes = (1...40).map { PaneID(rawValue: "w\($0 % 7):p\($0)") }
        let offsets = panes.map { TileTailCadence.offset(for: $0, interval: TileTailCadence.grid) }
        XCTAssertTrue(offsets.allSatisfy { $0 >= .zero && $0 < TileTailCadence.grid })
        XCTAssertGreaterThan(Set(offsets.map { $0.components.seconds }).count, 1, "every pane reads in the same second")
        XCTAssertEqual(
            TileTailCadence.offset(for: panes[0], interval: TileTailCadence.grid),
            TileTailCadence.offset(for: panes[0], interval: TileTailCadence.grid)
        )
    }

    func testATileDrawsTheNewestRowsThatFit() {
        XCTAssertEqual(TileTailCadence.shown(count: 20, fitting: 6), 14..<20)
        XCTAssertEqual(TileTailCadence.shown(count: 4, fitting: 6), 0..<4)
        XCTAssertEqual(TileTailCadence.shown(count: 4, fitting: 0), 4..<4)
    }
}
