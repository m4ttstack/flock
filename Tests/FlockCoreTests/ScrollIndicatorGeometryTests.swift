import XCTest
import CoreGraphics
@testable import FlockCore

/// The thumb a pane's scroll indicator paints for herdr's scroll state:
/// length is the viewport's share of everything scrollable, position is
/// how far above the tail the viewport sits.
final class ScrollIndicatorGeometryTests: XCTestCase {
    func testAtTheTailThereIsNoThumb() {
        let scroll = ScrollInfo(offsetFromBottom: 0, maxOffsetFromBottom: 300, viewportRows: 40)
        XCTAssertNil(ScrollIndicatorGeometry.thumb(for: scroll, trackLength: 400))
    }

    func testNothingScrollableMeansNoThumb() {
        XCTAssertNil(ScrollIndicatorGeometry.thumb(for: ScrollInfo(offsetFromBottom: 3, maxOffsetFromBottom: 0, viewportRows: 40), trackLength: 400))
        XCTAssertNil(ScrollIndicatorGeometry.thumb(for: ScrollInfo(offsetFromBottom: 3, maxOffsetFromBottom: 10, viewportRows: 0), trackLength: 400))
        XCTAssertNil(ScrollIndicatorGeometry.thumb(for: ScrollInfo(offsetFromBottom: 3, maxOffsetFromBottom: 10, viewportRows: 40), trackLength: 0))
    }

    func testThumbLengthIsTheViewportsShareOfTheWholeScrollback() {
        // 40 of 360 total rows visible over a 360pt track: a 40pt thumb.
        let scroll = ScrollInfo(offsetFromBottom: 100, maxOffsetFromBottom: 320, viewportRows: 40)
        let thumb = ScrollIndicatorGeometry.thumb(for: scroll, trackLength: 360, minimumLength: 0)!
        XCTAssertEqual(thumb.length, 40, accuracy: 1e-9)
    }

    func testThumbSitsProportionallyAboveTheTail() {
        // Scrolled 100 rows up of a 320 maximum: the thumb's top sits at
        // (320 - 100) / 320 of the travel (track minus thumb).
        let scroll = ScrollInfo(offsetFromBottom: 100, maxOffsetFromBottom: 320, viewportRows: 40)
        let thumb = ScrollIndicatorGeometry.thumb(for: scroll, trackLength: 360, minimumLength: 0)!
        XCTAssertEqual(thumb.offset, (360 - 40) * (220.0 / 320.0), accuracy: 1e-9)
    }

    func testFullyScrolledUpPutsTheThumbAtTheTop() {
        let scroll = ScrollInfo(offsetFromBottom: 320, maxOffsetFromBottom: 320, viewportRows: 40)
        let thumb = ScrollIndicatorGeometry.thumb(for: scroll, trackLength: 360)!
        XCTAssertEqual(thumb.offset, 0, accuracy: 1e-9)
    }

    func testMinimumLengthKeepsATinyViewportGrabbable() {
        let scroll = ScrollInfo(offsetFromBottom: 5, maxOffsetFromBottom: 100_000, viewportRows: 40)
        let thumb = ScrollIndicatorGeometry.thumb(for: scroll, trackLength: 300, minimumLength: 16)!
        XCTAssertEqual(thumb.length, 16, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(thumb.offset + thumb.length, 300 + 1e-9)
    }

    func testOffsetBeyondMaximumClampsToTheTop() {
        let scroll = ScrollInfo(offsetFromBottom: 500, maxOffsetFromBottom: 320, viewportRows: 40)
        let thumb = ScrollIndicatorGeometry.thumb(for: scroll, trackLength: 360)!
        XCTAssertEqual(thumb.offset, 0, accuracy: 1e-9)
    }

    // MARK: - a SwiftUI scroll view, in points

    func testContentThatFitsHasNoThumb() {
        XCTAssertNil(ScrollIndicatorGeometry.thumb(offset: 0, content: 400, visible: 400, trackLength: 400))
        XCTAssertNil(ScrollIndicatorGeometry.thumb(offset: 0, content: 300, visible: 400, trackLength: 400))
    }

    func testThePointThumbIsAsLongAsTheShareOnScreenAndStartsAtTheTop() throws {
        let thumb = try XCTUnwrap(ScrollIndicatorGeometry.thumb(offset: 0, content: 800, visible: 400, trackLength: 400))
        XCTAssertEqual(thumb.length, 200)
        XCTAssertEqual(thumb.offset, 0)
    }

    func testThePointThumbReachesTheTrackEndAtTheBottom() throws {
        let thumb = try XCTUnwrap(ScrollIndicatorGeometry.thumb(offset: 400, content: 800, visible: 400, trackLength: 400))
        XCTAssertEqual(thumb.offset, 200)
    }

    func testALongListKeepsAThumbLongEnoughToGrab() throws {
        let thumb = try XCTUnwrap(ScrollIndicatorGeometry.thumb(offset: 0, content: 40_000, visible: 400, trackLength: 400, minimumLength: 24))
        XCTAssertEqual(thumb.length, 24)
    }

    func testABounceKeepsThePointThumbInItsTrack() throws {
        let above = try XCTUnwrap(ScrollIndicatorGeometry.thumb(offset: -30, content: 800, visible: 400, trackLength: 400))
        XCTAssertEqual(above.offset, 0)
        let below = try XCTUnwrap(ScrollIndicatorGeometry.thumb(offset: 450, content: 800, visible: 400, trackLength: 400))
        XCTAssertEqual(below.offset, 200)
    }

    func testDraggingTheThumbAsksForTheOffsetThatPutsItThere() throws {
        let thumb = try XCTUnwrap(ScrollIndicatorGeometry.thumb(offset: 0, content: 800, visible: 400, trackLength: 400))
        func offset(_ y: CGFloat) -> CGFloat {
            ScrollIndicatorGeometry.contentOffset(forThumbAt: y, thumb: thumb, content: 800, visible: 400, trackLength: 400)
        }
        XCTAssertEqual(offset(100), 200)
        XCTAssertEqual(offset(-50), 0)
        XCTAssertEqual(offset(900), 400)
    }
}
