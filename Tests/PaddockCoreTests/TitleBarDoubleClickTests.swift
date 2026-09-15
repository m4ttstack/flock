import XCTest
@testable import PaddockCore

final class TitleBarDoubleClickTests: XCTestCase {
    func testUnsetPreferenceZooms() {
        XCTAssertEqual(TitleBarDoubleClickAction(action: nil, legacyMinimize: false), .zoom)
    }

    func testEachDesktopAndDockChoiceMapsToItsAction() {
        XCTAssertEqual(TitleBarDoubleClickAction(action: "Maximize", legacyMinimize: false), .zoom)
        XCTAssertEqual(TitleBarDoubleClickAction(action: "Fill", legacyMinimize: false), .fill)
        XCTAssertEqual(TitleBarDoubleClickAction(action: "Minimize", legacyMinimize: false), .minimize)
        XCTAssertEqual(TitleBarDoubleClickAction(action: "None", legacyMinimize: false), .doNothing)
    }

    func testLegacyMinimizeFlagAppliesOnlyWhenTheActionIsUnset() {
        XCTAssertEqual(TitleBarDoubleClickAction(action: nil, legacyMinimize: true), .minimize)
        XCTAssertEqual(TitleBarDoubleClickAction(action: "Maximize", legacyMinimize: true), .zoom)
    }

    func testUnrecognizedValueZooms() {
        XCTAssertEqual(TitleBarDoubleClickAction(action: "Something new", legacyMinimize: false), .zoom)
    }
}
