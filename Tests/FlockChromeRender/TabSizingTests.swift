import AppKit
import FlockCore
import XCTest

/// A tab is measured off the title it holds, in the real face the strip draws
/// it in.
final class TabSizingTests: XCTestCase {
    /// Everything a tab lays out beside its title.
    private static let chrome =
        ChromeMetrics.Tab.horizontalPadding * 2 + ChromeMetrics.Tab.labelDotGap + ChromeMetrics.Tab.statusDot

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

    func testAShortTitleStillGetsAWholeTab() {
        XCTAssertEqual(TabSizing.width(of: "M"), TabWidth.minimum)
    }

    func testATitleNoTabCanHoldStopsAtTheMaximum() {
        XCTAssertEqual(TabSizing.width(of: String(repeating: "wide ", count: 20)), TabWidth.maximum)
    }
}
