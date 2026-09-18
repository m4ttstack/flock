import CoreGraphics
import XCTest
@testable import FlockCore

/// A tab is drawn wide enough for the title it holds, between a floor that
/// keeps a one-letter name reading as a tab and a ceiling that keeps a long
/// one from taking the strip.
final class TabWidthTests: XCTestCase {
    /// The window strip's own chrome around a title, so the widths below are
    /// the tabs a user sees rather than an arrangement nothing draws: the
    /// padding either side, the gap after the title and the status dot.
    private func width(title: CGFloat) -> CGFloat {
        TabWidth.fitting(titleWidth: title, horizontalPadding: 12, labelDotGap: 6, statusDot: 6)
    }

    func testATitleThatFitsInsideTheMinimumLeavesTheTabAtIt() {
        XCTAssertEqual(width(title: 0), TabWidth.minimum)
        XCTAssertEqual(width(title: 20), TabWidth.minimum)
    }

    func testATitleTooWideForTheMinimumWidensTheTabToHoldIt() {
        XCTAssertEqual(width(title: 88), 124)
    }

    func testATitleTooWideForTheMaximumStopsThereAndTruncatesInstead() {
        XCTAssertEqual(width(title: 400), TabWidth.maximum)
    }

    /// Both bounds meet the fit exactly, so no title is given a tab with
    /// room it cannot use or a tab that clips what it just measured.
    func testEachBoundMeetsTheFitExactly() {
        XCTAssertEqual(width(title: 64), TabWidth.minimum)
        XCTAssertEqual(width(title: 164), TabWidth.maximum)
    }

    /// Measured text lands on fractions of a point. The chrome's surfaces are
    /// drawn on the pixel grid, and one fractional tab takes every tab after
    /// it off that grid too, so the fit is rounded up to a whole point ...
    /// up, because a title rounded down is a title truncated.
    func testAMeasuredTitleIsRoundedUpToAWholePoint() {
        XCTAssertEqual(width(title: 64.01), 101)
        XCTAssertEqual(width(title: 88.25), 125)
    }
}
