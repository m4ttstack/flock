import CoreGraphics
import XCTest
@testable import FlockCore

/// Where the strip's new-tab hover affordance sits: a tab-shaped box right
/// past the last tab's own gap, never stretched to fill whatever room is
/// left. Mirrors `DropZonesTests`: a run too short to hold one yields no
/// affordance at all.
final class NewTabAffordanceTests: XCTestCase {
    func testTheAffordanceTakesAnEmptyTabsOwnWidth() {
        XCTAssertEqual(NewTabAffordance.width, TabWidth.minimum)
    }

    func testItSitsRightPastTheLastTabsOwnGap() throws {
        let frame = try XCTUnwrap(
            NewTabAffordance.frame(tabsEnd: 332, gap: 3, viewportWidth: 900, height: 28)
        )
        XCTAssertEqual(frame, CGRect(x: 335, width: NewTabAffordance.width, height: 28))
    }

    func testItStartsAtTheStripsOwnLeadingEdgeWithNoTabsYet() throws {
        let frame = try XCTUnwrap(
            NewTabAffordance.frame(tabsEnd: 10, gap: 3, viewportWidth: 900, height: 28)
        )
        XCTAssertEqual(frame.minX, 13)
    }

    /// A strip already filled to its own visible edge draws none at all: an
    /// affordance only a scroll could reach is not "the empty space to the
    /// right of the last tab."
    func testNoAffordanceWhenTheStripHasNoUnscrolledRoomLeft() {
        XCTAssertNil(NewTabAffordance.frame(tabsEnd: 780, gap: 3, viewportWidth: 800, height: 28))
    }

    /// The boundary meets exactly: a viewport that holds the affordance to
    /// its very last point still draws it.
    func testTheBoundaryFitsExactly() throws {
        let frame = try XCTUnwrap(
            NewTabAffordance.frame(tabsEnd: 780, gap: 0, viewportWidth: 780 + TabWidth.minimum, height: 28)
        )
        XCTAssertEqual(frame.maxX, 780 + TabWidth.minimum)
    }
}

private extension CGRect {
    init(x: CGFloat, width: CGFloat, height: CGFloat) {
        self.init(x: x, y: 0, width: width, height: height)
    }
}
