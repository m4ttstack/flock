import XCTest
@testable import FlockCore

/// Ctrl-L, and nothing that merely looks like it. A false positive here costs
/// a pointless buffer scan and, if the screen happens to be small, the
/// launcher overlay landing on a pane the user is working in.
final class ClearKeyTests: XCTestCase {
    private func isClear(
        _ characters: String?, control: Bool = true, option: Bool = false,
        command: Bool = false, shift: Bool = false
    ) -> Bool {
        ClearKey.isClear(
            characters: characters, control: control, option: option, command: command, shift: shift
        )
    }

    func testControlLIsTheClearKey() {
        XCTAssertTrue(isClear("l"))
    }

    /// `charactersIgnoringModifiers` reports the unshifted key, but a keyboard
    /// layout or an input source reporting the capital must not slip past.
    func testTheCapitalFormMatchesToo() {
        XCTAssertTrue(isClear("L"))
    }

    func testAnyOtherKeyWithControlIsNotAClear() {
        XCTAssertFalse(isClear("c"))
        XCTAssertFalse(isClear("k"))
        XCTAssertFalse(isClear("u"))
    }

    func testPlainLIsNotAClear() {
        XCTAssertFalse(isClear("l", control: false))
    }

    /// Ctrl-Option-L and Ctrl-Shift-L are their own bindings in plenty of
    /// programs and say nothing about clearing.
    func testAStrayModifierIsNotAClear() {
        XCTAssertFalse(isClear("l", option: true))
        XCTAssertFalse(isClear("l", command: true))
        XCTAssertFalse(isClear("l", shift: true))
    }

    /// A dead key, a compose sequence or a function key can all arrive with no
    /// characters or with several.
    func testNoCharactersOrSeveralIsNotAClear() {
        XCTAssertFalse(isClear(nil))
        XCTAssertFalse(isClear(""))
        XCTAssertFalse(isClear("ll"))
    }
}
