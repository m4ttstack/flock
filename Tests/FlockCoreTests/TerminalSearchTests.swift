import XCTest
@testable import FlockCore

@MainActor
final class TerminalSearchTests: XCTestCase {
    func testOpeningRaisesTheFieldFocusBeforeTheFieldAsks() {
        let search = TerminalSearch()
        search.open(needle: nil)
        XCTAssertTrue(search.isOpen)
        XCTAssertTrue(search.fieldHasFocus)
    }

    /// A repeat Cmd+F on an open bar has to reach the view as a change, or the
    /// keyboard stays in the terminal.
    func testEveryOpenIsANewFocusRequest() {
        let search = TerminalSearch()
        search.open(needle: nil)
        let first = search.focusRequest
        search.open(needle: nil)
        XCTAssertNotEqual(search.focusRequest, first)
    }

    func testPlainOpenKeepsTheLastNeedleAndASelectionNeedleReplacesIt() {
        let search = TerminalSearch()
        search.needle = "acme"
        search.close()
        search.open(needle: nil)
        XCTAssertEqual(search.needle, "acme")
        search.open(needle: "")
        XCTAssertEqual(search.needle, "acme")
        search.open(needle: "widget")
        XCTAssertEqual(search.needle, "widget")
    }

    func testClosingDropsTheCountsAndTheKeyboard() {
        let search = TerminalSearch()
        search.open(needle: "acme")
        search.report(total: 3)
        search.report(selected: 1)
        search.close()
        XCTAssertFalse(search.isOpen)
        XCTAssertFalse(search.fieldHasFocus)
        XCTAssertNil(search.total)
        XCTAssertNil(search.selected)
        XCTAssertEqual(search.needle, "acme")
    }

    func testCountLabelFollowsWhatLibghosttyReported() {
        let search = TerminalSearch()
        search.open(needle: "acme")
        XCTAssertNil(search.countLabel)
        search.report(total: -1)
        XCTAssertNil(search.countLabel)
        search.report(total: 2)
        XCTAssertEqual(search.countLabel, "-/2")
        search.report(selected: 0)
        XCTAssertEqual(search.countLabel, "1/2")
        search.report(selected: -1)
        XCTAssertEqual(search.countLabel, "-/2")
    }

    func testAnEmptyNeedleShowsNoCount() {
        let search = TerminalSearch()
        search.open(needle: nil)
        search.report(total: 0)
        XCTAssertNil(search.countLabel)
    }

    func testOnlyShortNeedlesWait() {
        XCTAssertEqual(TerminalSearch.debounce(for: ""), .zero)
        XCTAssertEqual(TerminalSearch.debounce(for: "a"), .milliseconds(300))
        XCTAssertEqual(TerminalSearch.debounce(for: "ac"), .milliseconds(300))
        XCTAssertEqual(TerminalSearch.debounce(for: "acm"), .zero)
    }
}
