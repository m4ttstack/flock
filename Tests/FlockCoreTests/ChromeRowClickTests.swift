import XCTest
@testable import FlockCore

final class ChromeRowClickTests: XCTestCase {
    func testAPlainClickSelects() {
        XCTAssertEqual(ChromeRowClick.of(button: .primary, controlHeld: false, clickCount: 1), .select)
    }

    /// The row has no second gesture to hand the rename to, so the second
    /// click of a double arrives on the same tap and is recognized by its
    /// count alone.
    func testTheSecondClickOfADoubleOpensTheRenameEditor() {
        XCTAssertEqual(ChromeRowClick.of(button: .primary, controlHeld: false, clickCount: 2), .beginRename)
    }

    /// A third click would re-open an editor that is already open, throwing
    /// away whatever the first two clicks' editor had seeded.
    func testAThirdClickOpensNothingFurther() {
        XCTAssertEqual(ChromeRowClick.of(button: .primary, controlHeld: false, clickCount: 3), .ignore)
        XCTAssertEqual(ChromeRowClick.of(button: .primary, controlHeld: false, clickCount: 4), .ignore)
    }

    /// `NSApp.currentEvent` can be absent, and a non-mouse event has no click
    /// count at all; a click that reached the handler still selects.
    func testAClickWithNoCountStillSelects() {
        XCTAssertEqual(ChromeRowClick.of(button: .primary, controlHeld: false, clickCount: 0), .select)
    }

    /// The context menu owns both routes to a secondary click, and a
    /// double-tapped one must not rename either.
    func testASecondaryClickAsksForNothing() {
        XCTAssertEqual(ChromeRowClick.of(button: .secondary, controlHeld: false, clickCount: 1), .ignore)
        XCTAssertEqual(ChromeRowClick.of(button: .secondary, controlHeld: false, clickCount: 2), .ignore)
        XCTAssertEqual(ChromeRowClick.of(button: .primary, controlHeld: true, clickCount: 1), .ignore)
        XCTAssertEqual(ChromeRowClick.of(button: .primary, controlHeld: true, clickCount: 2), .ignore)
    }
}
