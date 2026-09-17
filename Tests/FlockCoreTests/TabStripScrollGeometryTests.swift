import CoreGraphics
import XCTest
@testable import FlockCore

final class TabStripScrollGeometryTests: XCTestCase {
    // MARK: - wheelOffset

    private let step: CGFloat = 103

    private func wheel(
        current: CGFloat = 100, maximumOffset: CGFloat = 300, deltaX: CGFloat = 0, deltaY: CGFloat, precise: Bool = true
    ) -> CGFloat? {
        TabStripScrollGeometry.wheelOffset(
            current: current, maximumOffset: maximumOffset,
            deltaX: deltaX, deltaY: deltaY, precise: precise, lineStep: step
        )
    }

    func testAPlainVerticalWheelScrollsTheStripHorizontally() {
        XCTAssertEqual(wheel(deltaY: 10), 90)
        XCTAssertEqual(wheel(deltaY: -10), 110)
    }

    /// The same raw delta means points from a trackpad and LINES from a
    /// classic wheel. Read as points a notch moves the strip 1pt against a
    /// 103pt tab pitch, which is the difference between working and not.
    func testTheSameRawDeltaIsPointsFromATrackpadAndAWholeTabFromAWheel() {
        XCTAssertEqual(wheel(current: 300, deltaY: 1, precise: true), 299)
        XCTAssertEqual(wheel(current: 300, deltaY: 1, precise: false), 300 - step)
        XCTAssertEqual(wheel(current: 0, deltaY: -1, precise: false), step)
    }

    /// macOS delivers 0.1 for a slow wheel click; rounding the magnitude out
    /// to a full notch is what keeps that click worth a tab.
    func testASlowWheelClicksFractionalNotchStillMovesAWholeTab() {
        XCTAssertEqual(wheel(current: 300, deltaY: 0.1, precise: false), 300 - step)
        XCTAssertEqual(wheel(current: 0, deltaY: -0.1, precise: false), step)
    }

    func testAMultiLineWheelDeltaScalesWithTheNotchCount() {
        XCTAssertEqual(wheel(current: 400, maximumOffset: 900, deltaY: 3, precise: false), 400 - 3 * step)
        XCTAssertEqual(wheel(current: 0, maximumOffset: 900, deltaY: -3, precise: false), 3 * step)
    }

    func testATrackpadSwipeWithAHorizontalComponentIsLeftAlone() {
        XCTAssertNil(wheel(deltaX: 5, deltaY: 10))
        XCTAssertNil(wheel(deltaX: -5, deltaY: 0))
    }

    func testAZeroVerticalDeltaIsLeftAlone() {
        XCTAssertNil(wheel(deltaY: 0))
    }

    /// Nothing overflows, so there is nothing to scroll and no reason to
    /// swallow the event.
    func testAStripWithNothingHiddenPassesTheWheelThrough() {
        XCTAssertNil(wheel(current: 0, maximumOffset: 0, deltaY: 10))
        XCTAssertNil(wheel(current: 0, maximumOffset: 0, deltaY: 10, precise: false))
    }

    func testWheelOffsetClampsToTheStripsRun() {
        XCTAssertEqual(wheel(current: 5, deltaY: 50), 0)
        XCTAssertEqual(wheel(current: 295, deltaY: -50), 300)
        XCTAssertEqual(wheel(current: 295, deltaY: -1, precise: false), 300)
    }

    // MARK: - revealOffset

    func testATabAlreadyFullyVisibleIsNotScrolled() {
        let frame = CGRect(x: 50, y: 0, width: 100, height: 28)
        XCTAssertNil(TabStripScrollGeometry.revealOffset(for: frame, offset: 0, viewportWidth: 400, maximumOffset: 300))
    }

    func testATabHiddenPastTheLeadingEdgeScrollsToItsLeadingEdge() {
        let frame = CGRect(x: 50, y: 0, width: 100, height: 28)
        XCTAssertEqual(
            TabStripScrollGeometry.revealOffset(for: frame, offset: 120, viewportWidth: 400, maximumOffset: 300), 50
        )
    }

    func testATabHiddenPastTheTrailingEdgeScrollsToShowItsTrailingEdge() {
        let frame = CGRect(x: 500, y: 0, width: 100, height: 28)
        XCTAssertEqual(
            TabStripScrollGeometry.revealOffset(for: frame, offset: 0, viewportWidth: 400, maximumOffset: 300), 200
        )
    }

    func testRevealOffsetClampsWithinTheStripsRun() {
        let frame = CGRect(x: 0, y: 0, width: 100, height: 28)
        XCTAssertEqual(
            TabStripScrollGeometry.revealOffset(for: frame, offset: 250, viewportWidth: 400, maximumOffset: 300), 0
        )
        let trailingFrame = CGRect(x: 900, y: 0, width: 100, height: 28)
        XCTAssertEqual(
            TabStripScrollGeometry.revealOffset(for: trailingFrame, offset: 0, viewportWidth: 400, maximumOffset: 300),
            300
        )
    }

    func testATabWiderThanTheViewportAlignsItsLeadingEdge() {
        let frame = CGRect(x: 100, y: 0, width: 500, height: 28)
        XCTAssertEqual(
            TabStripScrollGeometry.revealOffset(for: frame, offset: 0, viewportWidth: 400, maximumOffset: 300), 100
        )
    }

    // MARK: - edgeFade

    func testNothingFadesWhenTheStripDoesNotOverflow() {
        XCTAssertEqual(TabStripScrollGeometry.edgeFade(offset: 0, maximumOffset: 0), .none)
        XCTAssertEqual(TabStripScrollGeometry.edgeFade(offset: 0, maximumOffset: -1), .none)
    }

    func testAtTheLeadingEdgeOnlyTheTrailingEdgeFades() {
        let fade = TabStripScrollGeometry.edgeFade(offset: 0, maximumOffset: 300)
        XCTAssertFalse(fade.leading)
        XCTAssertTrue(fade.trailing)
    }

    func testAtTheTrailingEdgeOnlyTheLeadingEdgeFades() {
        let fade = TabStripScrollGeometry.edgeFade(offset: 300, maximumOffset: 300)
        XCTAssertTrue(fade.leading)
        XCTAssertFalse(fade.trailing)
    }

    func testScrolledPastEitherEdgeBothEdgesFade() {
        let fade = TabStripScrollGeometry.edgeFade(offset: 150, maximumOffset: 300)
        XCTAssertTrue(fade.leading)
        XCTAssertTrue(fade.trailing)
    }
}
