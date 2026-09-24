import XCTest
@testable import FlockCore

/// AppKit binds Ctrl-Return to "show context menu" as a key equivalent, so a
/// pane that does not claim it pops the pane menu instead of the program in it
/// (Claude Code's send-now, for one) ever seeing the key.
final class ControlReturnKeyTests: XCTestCase {
    private func claims(
        _ characters: String?, control: Bool = true, command: Bool = false
    ) -> Bool {
        ControlReturnKey.isTerminalInput(characters: characters, control: control, command: command)
    }

    func testControlReturnIsTerminalInput() {
        XCTAssertTrue(claims("\r"))
    }

    func testPlainReturnIsLeftToKeyDown() {
        XCTAssertFalse(claims("\r", control: false))
    }

    /// Command combos are the menu bar's to match first.
    func testCommandControlReturnIsLeftToTheMenus() {
        XCTAssertFalse(claims("\r", command: true))
    }

    func testOtherControlKeysAreNotClaimed() {
        XCTAssertFalse(claims("c"))
        XCTAssertFalse(claims("/"))
        XCTAssertFalse(claims(nil))
    }
}
