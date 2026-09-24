import XCTest
@testable import FlockCore

/// A plain right-click goes to the focused pane's program once it has claimed
/// the mouse; Option, a plain shell, or an unfocused pane gets the herdr menu.
final class RightClickDispositionTests: XCTestCase {
    // MARK: - The focused pane

    func testFocusedCapturingPanesPlainClickGoesToItsProgram() {
        XCTAssertEqual(
            RightClickDisposition.decide(optionHeld: false, captureEnabled: true, paneIsFocused: true),
            .forwardToPane,
            "the program claimed the mouse, so a plain right-click is its click")
    }

    func testOptionOpensTheMenuEvenWhenTheProgramIsListening() {
        XCTAssertEqual(
            RightClickDisposition.decide(optionHeld: true, captureEnabled: true, paneIsFocused: true),
            .menu,
            "Option is the escape hatch to the menu out of a listening program")
    }

    func testAPlainShellGetsTheMenu() {
        for option in [false, true] {
            XCTAssertEqual(
                RightClickDisposition.decide(optionHeld: option, captureEnabled: false, paneIsFocused: true),
                .menu,
                "nothing in the pane reads the click, so it falls through to the menu (option=\(option))")
        }
    }

    // MARK: - An unfocused pane

    /// herdr reports mouse capture to EVERY attached pane, so a background
    /// pane running an agent reports capture on. Forwarding that click would
    /// hand it to `MouseForwarding`, which drops every event for an unfocused
    /// pane: the click would reach neither the menu nor the program.
    func testAnUnfocusedPaneAlwaysGetsTheMenu() {
        for option in [false, true] {
            for capture in [false, true] {
                XCTAssertEqual(
                    RightClickDisposition.decide(optionHeld: option, captureEnabled: capture, paneIsFocused: false),
                    .menu,
                    "an unfocused pane forwards nothing (option=\(option) capture=\(capture))")
            }
        }
    }

    // MARK: - Rearrange mode: neither the menu nor the pane

    /// Rearrange mode wins over every other input: the whole pane is a drag
    /// surface while it is on, so no right-click reaches the rule below it,
    /// Option held or not.
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
}
