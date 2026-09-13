import XCTest
@testable import PaddockCore

/// Pins the exact per-size pitch at scale 2x: ghostty rounds `cell_height`
/// to a whole device pixel before returning it (26/30/35px for Menlo
/// compact/regular/large -- see `TerminalRowPitch`'s own doc comment), so
/// dividing by the scale lands on 13.0/15.0/17.5pt exactly, never an
/// unrounded font-metric value.
final class TerminalRowPitchTests: XCTestCase {
    func testPointsAtScale2xForEachSize() {
        XCTAssertEqual(TerminalRowPitch.points(cellHeightPx: 26, scale: 2), 13.0)
        XCTAssertEqual(TerminalRowPitch.points(cellHeightPx: 30, scale: 2), 15.0)
        XCTAssertEqual(TerminalRowPitch.points(cellHeightPx: 35, scale: 2), 17.5)
    }

    func testPointsAtScale1x() {
        XCTAssertEqual(TerminalRowPitch.points(cellHeightPx: 30, scale: 1), 30.0)
    }

    func testZeroScaleFallsBackToRawPixelCountRatherThanDividingByZero() {
        XCTAssertEqual(TerminalRowPitch.points(cellHeightPx: 30, scale: 0), 30.0)
    }

    /// N stacked rows occupy exactly N times one row's own pitch -- never a
    /// separately-computed sum that could round differently.
    func testTotalHeightForNRowsIsExactlyNTimesOneRowsPitch() {
        for rows in [1, 5, 40] {
            let expected = Double(rows) * TerminalRowPitch.points(cellHeightPx: 30, scale: 2)
            XCTAssertEqual(TerminalRowPitch.totalHeight(rowCount: rows, cellHeightPx: 30, scale: 2), expected)
        }
        XCTAssertEqual(TerminalRowPitch.totalHeight(rowCount: 40, cellHeightPx: 30, scale: 2), 600.0)
    }
}
