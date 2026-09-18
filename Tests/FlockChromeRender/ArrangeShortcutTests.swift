import SwiftUI
import XCTest

/// The arrange pair is a decision, not an accident, so both halves are pinned:
/// the key itself, and the rule that the wider-scope item is that same key
/// with Shift. `ArrangeShortcut` carries why the key is what it is.
final class ArrangeShortcutTests: XCTestCase {
    func testRearrangeModeTakesCommandR() {
        XCTAssertEqual(ArrangeShortcut.rearrangeMode.key, "r")
        XCTAssertEqual(ArrangeShortcut.rearrangeMode.modifiers, .command)
    }

    func testAllWorkspacesIsTheShiftedRearrangeKey() {
        XCTAssertEqual(
            ArrangeShortcut.allWorkspaces.key, ArrangeShortcut.rearrangeMode.key,
            "the two items are one gesture at two scopes, so they share a key"
        )
        XCTAssertEqual(ArrangeShortcut.allWorkspaces.modifiers, [.command, .shift])
    }
}
