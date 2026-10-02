import AppKit
import FlockCore
import XCTest

/// A tab is measured off the title it holds, in the real face the strip draws
/// it in.
final class TabSizingTests: XCTestCase {
    /// Everything a tab lays out beside its title.
    private static let chrome =
        ChromeMetrics.Tab.horizontalPadding * 2 + ChromeMetrics.Tab.labelDotGap + ChromeMetrics.Tab.trailingSlot

    override func setUp() {
        super.setUp()
        ChromeType.install()
    }

    private func titleWidth(_ title: String, selected: Bool) throws -> CGFloat {
        let weight = ChromeType.tabLabelWeight(selected: selected)
        let font = try XCTUnwrap(NSFont(name: weight.postScriptName, size: ChromeType.tabLabelSize))
        return (title as NSString).size(withAttributes: [.font: font]).width
    }

    /// A tab's label is set in Inter Medium while it is selected and Regular
    /// while it is not, so a tab measured in its own state would widen as the
    /// selection reached it and carry every tab after it along the strip. One
    /// width has to hold both faces, which makes it the wider one's.
    func testATabHoldsItsTitleInEitherOfTheFacesItIsDrawnIn() throws {
        let title = "Trash Runner"
        let resting = try titleWidth(title, selected: false)
        let selected = try titleWidth(title, selected: true)
        XCTAssertGreaterThan(selected, resting, "the two faces measure the same, so this test proves nothing")

        XCTAssertGreaterThanOrEqual(TabSizing.width(of: title), selected + Self.chrome)
    }

    /// The close is revealed in the status dot's place and is wider than it.
    /// A tab sized for the dot alone hands the close no room of its own, and
    /// it takes the title's.
    func testATabKeepsRoomForTheCloseAndNotJustTheDot() {
        XCTAssertGreaterThan(
            ChromeMetrics.CloseButton.size, ChromeMetrics.Tab.statusDot,
            "the close already fits the dot's room, so this test proves nothing"
        )
        XCTAssertGreaterThanOrEqual(ChromeMetrics.Tab.trailingSlot, ChromeMetrics.CloseButton.size)

        let title = "Trash Runner"
        let measured = try? titleWidth(title, selected: true)
        XCTAssertGreaterThanOrEqual(
            TabSizing.width(of: title),
            (measured ?? 0) + ChromeMetrics.Tab.horizontalPadding * 2
                + ChromeMetrics.Tab.labelDotGap + ChromeMetrics.CloseButton.size
        )
    }

    /// A title borrowed from the pane is led by the pane glyph, which takes
    /// room of its own rather than the title's.
    func testAPaneTitledTabMakesRoomForItsGlyph() {
        let title = "Trash Runner"
        let named = TabSizing.width(of: TabTitle(text: title, isFromPane: false))
        XCTAssertEqual(named, TabSizing.width(of: title))
        XCTAssertLessThan(named, TabWidth.maximum - 40, "the title is near the maximum, so this test proves nothing")

        let borrowed = TabSizing.width(of: TabTitle(text: title, isFromPane: true))
        XCTAssertGreaterThanOrEqual(borrowed, named + ChromeMetrics.Tab.paneGlyphWidth + ChromeMetrics.Tab.paneGlyphGap - 1)
    }

    /// A complete tab's checkmark leads everything else in it, the pane glyph
    /// included, and takes room of its own rather than the title's.
    func testACompleteTabMakesRoomForItsCheckmark() {
        let check = ChromeMetrics.Tab.completeGlyphWidth + ChromeMetrics.Tab.completeGlyphGap
        for isFromPane in [false, true] {
            let title = TabTitle(text: "Trash Runner", isFromPane: isFromPane)
            let open = TabSizing.width(of: title)
            XCTAssertLessThan(open, TabWidth.maximum - 40, "the title is near the maximum, so this test proves nothing")

            XCTAssertGreaterThanOrEqual(TabSizing.width(of: title, isComplete: true, isSelected: true), open + check - 1)
        }
    }

    /// A complete tab nobody is looking at is compact; selecting it gives
    /// back the room any other tab would have.
    func testACompleteTabIsCompactUntilSelected() {
        let title = TabTitle(text: String(repeating: "wide ", count: 20), isFromPane: false)

        XCTAssertEqual(TabSizing.width(of: title, isComplete: true), TabWidth.compactMaximum)
        XCTAssertEqual(TabSizing.width(of: title, isComplete: true, isSelected: true), TabWidth.maximum)
        XCTAssertEqual(TabSizing.width(of: TabTitle(text: "M", isFromPane: false), isComplete: true), TabWidth.compactMinimum)
    }

    func testAShortTitleStillGetsAWholeTab() {
        XCTAssertEqual(TabSizing.width(of: "M"), TabWidth.minimum)
    }

    func testATitleNoTabCanHoldStopsAtTheMaximum() {
        XCTAssertEqual(TabSizing.width(of: String(repeating: "wide ", count: 20)), TabWidth.maximum)
    }
}
