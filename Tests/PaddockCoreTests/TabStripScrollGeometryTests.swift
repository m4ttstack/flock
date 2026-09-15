import CoreGraphics
import XCTest
@testable import PaddockCore

final class TabStripScrollGeometryTests: XCTestCase {
    // MARK: - wheelOffset

    func testAPlainVerticalWheelScrollsTheStripHorizontally() {
        XCTAssertEqual(
            TabStripScrollGeometry.wheelOffset(current: 100, maximumOffset: 300, deltaX: 0, deltaY: 10), 90
        )
        XCTAssertEqual(
            TabStripScrollGeometry.wheelOffset(current: 100, maximumOffset: 300, deltaX: 0, deltaY: -10), 110
        )
    }

    func testATrackpadSwipeWithAHorizontalComponentIsLeftAlone() {
        XCTAssertNil(TabStripScrollGeometry.wheelOffset(current: 100, maximumOffset: 300, deltaX: 5, deltaY: 10))
        XCTAssertNil(TabStripScrollGeometry.wheelOffset(current: 100, maximumOffset: 300, deltaX: -5, deltaY: 0))
    }

    func testAZeroVerticalDeltaIsLeftAlone() {
        XCTAssertNil(TabStripScrollGeometry.wheelOffset(current: 100, maximumOffset: 300, deltaX: 0, deltaY: 0))
    }

    func testWheelOffsetClampsToTheStripsRun() {
        XCTAssertEqual(TabStripScrollGeometry.wheelOffset(current: 5, maximumOffset: 300, deltaX: 0, deltaY: 50), 0)
        XCTAssertEqual(TabStripScrollGeometry.wheelOffset(current: 295, maximumOffset: 300, deltaX: 0, deltaY: -50), 300)
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
