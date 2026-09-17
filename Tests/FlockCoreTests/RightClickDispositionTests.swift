import XCTest
@testable import FlockCore

/// A right-click opens the herdr menu unless this pane has passthrough turned
/// on, which is herdr's own default for a fresh pane.
final class RightClickDispositionTests: XCTestCase {
    // MARK: - Passthrough off: the menu, whatever else is true

    /// The case that matters in practice: a pane running an agent reports
    /// mouse capture, and the menu still has to be reachable in it.
    func testCaptureOnStillShowsTheMenuWhilePassthroughIsOff() {
        XCTAssertEqual(
            RightClickDisposition.decide(optionHeld: false, captureEnabled: true, paneIsFocused: true),
            .menu,
            "a mouse-reporting program does not take the click until passthrough is turned on")
    }

    func testPassthroughOffShowsTheMenuForEveryOtherCombination() {
        for option in [false, true] {
            for capture in [false, true] {
                for focused in [false, true] {
                    XCTAssertEqual(
                        RightClickDisposition.decide(
                            optionHeld: option, captureEnabled: capture, paneIsFocused: focused
                        ),
                        .menu,
                        "passthrough off means the menu (option=\(option) capture=\(capture) focused=\(focused))")
                }
            }
        }
    }

    // MARK: - Passthrough on

    func testPassthroughOnForwardsAFocusedCapturingPanesClick() {
        XCTAssertEqual(
            RightClickDisposition.decide(
                optionHeld: false, captureEnabled: true, paneIsFocused: true, passthroughEnabled: true
            ),
            .forwardToPane,
            "with passthrough on, the program that claimed the mouse gets its click")
    }

    func testPassthroughOnStillShowsTheMenuWithNothingListening() {
        XCTAssertEqual(
            RightClickDisposition.decide(
                optionHeld: false, captureEnabled: false, paneIsFocused: true, passthroughEnabled: true
            ),
            .menu,
            "a plain shell reads nothing, so the click falls through to the menu")
    }

    /// herdr reports mouse capture to EVERY attached pane, so a background
    /// pane running an agent reports capture on. Forwarding that click would
    /// hand it to `MouseForwarding`, which drops every event for an unfocused
    /// pane: the click would reach neither the menu nor the program.
    func testPassthroughOnStillShowsTheMenuOnAnUnfocusedPane() {
        for capture in [false, true] {
            XCTAssertEqual(
                RightClickDisposition.decide(
                    optionHeld: false, captureEnabled: capture, paneIsFocused: false, passthroughEnabled: true
                ),
                .menu,
                "an unfocused pane forwards nothing (capture=\(capture))")
        }
    }

    // MARK: - Rearrange mode: neither the menu nor the pane

    /// Rearrange mode wins over every other input, and Option is how it is
    /// entered, so an Option right-click never reaches the rule below it.
    func testRearrangeActiveIsAlwaysSuppressed() {
        for option in [false, true] {
            for capture in [false, true] {
                for focused in [false, true] {
                    for passthrough in [false, true] {
                        XCTAssertEqual(
                            RightClickDisposition.decide(
                                optionHeld: option,
                                captureEnabled: capture,
                                paneIsFocused: focused,
                                rearrangeActive: true,
                                passthroughEnabled: passthrough
                            ),
                            .suppressed,
                            "rearrange mode must suppress the right-click (option=\(option) capture=\(capture) focused=\(focused) passthrough=\(passthrough))"
                        )
                    }
                }
            }
        }
    }
}
