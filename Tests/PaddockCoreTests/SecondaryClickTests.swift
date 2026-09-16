import XCTest
@testable import PaddockCore

final class SecondaryClickTests: XCTestCase {
    func testTheSecondaryButtonIsSecondaryHeldControlOrNot() {
        XCTAssertTrue(SecondaryClick.isSecondary(button: .secondary, controlHeld: false))
        XCTAssertTrue(SecondaryClick.isSecondary(button: .secondary, controlHeld: true))
    }

    /// macOS's second way to ask for a context menu: it reaches a tap handler
    /// as an ordinary left click, so without this the guard would let it
    /// through and the handler would act on a menu request.
    func testAControlHeldPrimaryClickIsSecondary() {
        XCTAssertTrue(SecondaryClick.isSecondary(button: .primary, controlHeld: true))
    }

    func testAPlainPrimaryClickIsNotSecondary() {
        XCTAssertFalse(SecondaryClick.isSecondary(button: .primary, controlHeld: false))
    }

    /// Control alone must never make a click secondary: a middle button or a
    /// key event carries no context-menu intent whatever is held with it.
    func testAnyOtherButtonIsNeverSecondary() {
        XCTAssertFalse(SecondaryClick.isSecondary(button: .other, controlHeld: false))
        XCTAssertFalse(SecondaryClick.isSecondary(button: .other, controlHeld: true))
    }
}
