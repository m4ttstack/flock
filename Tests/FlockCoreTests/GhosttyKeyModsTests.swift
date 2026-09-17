import XCTest
import GhosttyKit
@testable import FlockCore

final class GhosttyKeyModsTests: XCTestCase {
    func testNoModifiersTranslatesToNone() {
        XCTAssertEqual(GhosttyKeyMods.translate([]).rawValue, GHOSTTY_MODS_NONE.rawValue)
    }

    func testShiftAlone() {
        XCTAssertEqual(GhosttyKeyMods.translate(.shift).rawValue, GHOSTTY_MODS_SHIFT.rawValue)
    }

    func testControlAlone() {
        XCTAssertEqual(GhosttyKeyMods.translate(.control).rawValue, GHOSTTY_MODS_CTRL.rawValue)
    }

    func testOptionAlone() {
        XCTAssertEqual(GhosttyKeyMods.translate(.option).rawValue, GHOSTTY_MODS_ALT.rawValue)
    }

    func testCommandAlone() {
        XCTAssertEqual(GhosttyKeyMods.translate(.command).rawValue, GHOSTTY_MODS_SUPER.rawValue)
    }

    func testCapsLockAlone() {
        XCTAssertEqual(GhosttyKeyMods.translate(.capsLock).rawValue, GHOSTTY_MODS_CAPS.rawValue)
    }

    func testShiftControlCombination() {
        let expected = UInt32(GHOSTTY_MODS_SHIFT.rawValue) | UInt32(GHOSTTY_MODS_CTRL.rawValue)
        XCTAssertEqual(GhosttyKeyMods.translate([.shift, .control]).rawValue, expected)
    }

    func testOptionCommandCombination() {
        let expected = UInt32(GHOSTTY_MODS_ALT.rawValue) | UInt32(GHOSTTY_MODS_SUPER.rawValue)
        XCTAssertEqual(GhosttyKeyMods.translate([.option, .command]).rawValue, expected)
    }

    func testAllFiveModifiersTogether() {
        let expected = UInt32(GHOSTTY_MODS_SHIFT.rawValue)
            | UInt32(GHOSTTY_MODS_CTRL.rawValue)
            | UInt32(GHOSTTY_MODS_ALT.rawValue)
            | UInt32(GHOSTTY_MODS_SUPER.rawValue)
            | UInt32(GHOSTTY_MODS_CAPS.rawValue)
        XCTAssertEqual(
            GhosttyKeyMods.translate([.shift, .control, .option, .command, .capsLock]).rawValue,
            expected
        )
    }

    /// `OptionSet` de-duplicates: asking twice does not double a bit.
    func testRepeatedInsertionIsIdempotent() {
        var flags: GhosttyKeyModifiers = [.shift]
        flags.insert(.shift)
        XCTAssertEqual(GhosttyKeyMods.translate(flags).rawValue, GHOSTTY_MODS_SHIFT.rawValue)
    }
}
