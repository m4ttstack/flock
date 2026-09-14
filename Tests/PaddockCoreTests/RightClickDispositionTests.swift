import XCTest
@testable import PaddockCore

/// Right-clicks land in the focused pane by default; Option summons the herdr
/// menu, and an unfocused pane always gets the menu.
final class RightClickDispositionTests: XCTestCase {
    // MARK: - The focused pane

    func testFocusedCaptureOnPlainRightClickForwardsToPane() {
        XCTAssertEqual(
            RightClickDisposition.decide(optionHeld: false, captureEnabled: true, paneIsFocused: true),
            .forwardToPane,
            "the pane app claimed the mouse, so a plain right-click is its click")
    }

    func testFocusedCaptureOnWithOptionShowsTheMenu() {
        XCTAssertEqual(
            RightClickDisposition.decide(optionHeld: true, captureEnabled: true, paneIsFocused: true),
            .menu,
            "Option is the deliberate gesture for the herdr action menu")
    }

    func testFocusedCaptureOffShowsTheMenu() {
        XCTAssertEqual(
            RightClickDisposition.decide(optionHeld: false, captureEnabled: false, paneIsFocused: true),
            .menu,
            "nothing is listening in a plain shell, so fall through to the menu")
        XCTAssertEqual(
            RightClickDisposition.decide(optionHeld: true, captureEnabled: false, paneIsFocused: true),
            .menu)
    }

    // MARK: - Rearrange mode: neither the menu nor the pane

    /// Rearrange mode wins over every other input -- focus, Option, capture
    /// -- so a right-click during rearrange never opens the herdr menu and
    /// never reaches the pane app either.
    func testRearrangeActiveIsAlwaysSuppressed() {
        for option in [false, true] {
            for capture in [false, true] {
                for focused in [false, true] {
                    XCTAssertEqual(
                        RightClickDisposition.decide(
                            optionHeld: option, captureEnabled: capture, paneIsFocused: focused, rearrangeActive: true
                        ),
                        .suppressed,
                        "rearrange mode must suppress the right-click (option=\(option) capture=\(capture) focused=\(focused))"
                    )
                }
            }
        }
    }

    // MARK: - Any other pane: always the menu, forwarding never happens

    /// herdr reports mouse capture to EVERY attached pane, so a background
    /// pane running vim or claude reports capture on. Forwarding that click
    /// would hand it to `MouseForwarding`, which drops every event for an
    /// unfocused pane: the click would reach neither the menu nor the program.
    func testAnUnfocusedPaneAlwaysShowsTheMenuEvenUnderCapture() {
        for option in [false, true] {
            for capture in [false, true] {
                XCTAssertEqual(
                    RightClickDisposition.decide(optionHeld: option, captureEnabled: capture, paneIsFocused: false),
                    .menu,
                    "the herdr menu works on any pane; an unfocused pane forwards nothing (option=\(option) capture=\(capture))")
            }
        }
    }
}
