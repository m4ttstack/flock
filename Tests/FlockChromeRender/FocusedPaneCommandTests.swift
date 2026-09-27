import FlockCore
import SwiftUI
import XCTest

/// The focused-pane commands are a keyboard decision, so both halves are
/// pinned: the keys themselves, and the rule that each one runs the verb its
/// right-click row runs. `FocusedPaneCommand` carries why the keys are what
/// they are.
final class FocusedPaneCommandTests: XCTestCase {
    func testSplitRightTakesCommandD() {
        XCTAssertEqual(FocusedPaneCommand.splitRight.key, "d")
        XCTAssertEqual(FocusedPaneCommand.splitRight.modifiers, .command)
    }

    func testSplitDownIsTheShiftedSplitKey() {
        XCTAssertEqual(
            FocusedPaneCommand.splitDown.key, FocusedPaneCommand.splitRight.key,
            "one split key, and Shift is which way it goes"
        )
        XCTAssertEqual(FocusedPaneCommand.splitDown.modifiers, [.command, .shift])
    }

    func testClosePaneTakesCommandShiftX() {
        XCTAssertEqual(FocusedPaneCommand.closePane.key, "x")
        XCTAssertEqual(FocusedPaneCommand.closePane.modifiers, [.command, .shift])
    }

    func testZoomTakesGhosttysSplitZoomKey() {
        XCTAssertEqual(KeyEquivalent(FocusedPaneCommand.zoom.key), .return)
        XCTAssertEqual(FocusedPaneCommand.zoom.modifiers, [.command, .shift])
    }

    func testZoomIsTitledForWhatItWillDo() {
        XCTAssertEqual(FocusedPaneCommand.zoom.title(zoomed: false), "Zoom Pane")
        XCTAssertEqual(FocusedPaneCommand.zoom.title(zoomed: true), "Unzoom Pane")
        XCTAssertEqual(FocusedPaneCommand.splitRight.title(zoomed: true), "Split Right", "only the zoom row is a toggle")
    }

    func testEachCommandCarriesItsPaneMenuRowsAction() {
        XCTAssertEqual(FocusedPaneCommand.all.map(\.action), [.splitRight, .splitDown, .zoom, .closePane])
    }

    /// The arrange pair sits on R to leave the split keys alone; this fails if
    /// either side moves onto the other's key.
    func testNoCommandCollidesWithTheArrangeKey() {
        for command in FocusedPaneCommand.all {
            XCTAssertNotEqual(command.key, ArrangeShortcut.rearrangeMode.key, command.title)
        }
    }
}
