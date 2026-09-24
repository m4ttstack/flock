import XCTest
@testable import FlockCore

/// A focused pane whose program has the mouse sends a plain right-click where
/// its mode says and an Option right-click the other way. The rt modal has no
/// menu, so its program gets every right-click. A plain shell, an unfocused
/// pane, or rearrange mode ignores the mode.
final class RightClickDispositionTests: XCTestCase {
    private func decide(option: Bool, mode: RightClickMode) -> RightClickDisposition {
        RightClickDisposition.decide(optionHeld: option, captureEnabled: true, paneIsFocused: true, mode: mode)
    }

    // MARK: - A focused pane whose program has the mouse

    func testInMenuModeAPlainRightClickOpensTheMenuAndOptionReachesTheProgram() {
        XCTAssertEqual(decide(option: false, mode: .menu), .menu)
        XCTAssertEqual(decide(option: true, mode: .menu), .forwardToPane)
    }

    func testInProgramModeAPlainRightClickReachesTheProgramAndOptionOpensTheMenu() {
        XCTAssertEqual(decide(option: false, mode: .program), .forwardToPane)
        XCTAssertEqual(decide(option: true, mode: .program), .menu)
    }

    func testInTheModalEveryRightClickReachesTheProgram() {
        for option in [false, true] {
            XCTAssertEqual(decide(option: option, mode: .programOnly), .forwardToPane, "option=\(option)")
        }
    }

    func testAPaneStartsInProgramMode() {
        XCTAssertEqual(RightClickDisposition.decide(optionHeld: false, captureEnabled: true, paneIsFocused: true), .forwardToPane)
    }

    // MARK: - Nothing listening

    func testAPlainShellGetsTheMenuInEveryMode() {
        for mode in RightClickMode.allCases {
            for option in [false, true] {
                XCTAssertEqual(
                    RightClickDisposition.decide(optionHeld: option, captureEnabled: false, paneIsFocused: true, mode: mode),
                    .menu,
                    "nothing in the pane reads the click (mode=\(mode) option=\(option))")
            }
        }
    }

    // MARK: - An unfocused pane

    /// herdr reports mouse capture to EVERY attached pane, so a background
    /// pane running an agent reports capture on. Forwarding that click would
    /// hand it to `MouseForwarding`, which drops every event for an unfocused
    /// pane: the click would reach neither the menu nor the program.
    func testAnUnfocusedPaneAlwaysGetsTheMenu() {
        for mode in RightClickMode.allCases {
            for option in [false, true] {
                for capture in [false, true] {
                    XCTAssertEqual(
                        RightClickDisposition.decide(
                            optionHeld: option, captureEnabled: capture, paneIsFocused: false, mode: mode
                        ),
                        .menu,
                        "an unfocused pane forwards nothing (mode=\(mode) option=\(option) capture=\(capture))")
                }
            }
        }
    }

    // MARK: - Rearrange mode: neither the menu nor the pane

    /// Rearrange mode wins over every other input: the whole pane is a drag
    /// surface while it is on, so no right-click reaches the rule below it.
    func testRearrangeActiveIsAlwaysSuppressed() {
        for mode in RightClickMode.allCases {
            for option in [false, true] {
                for capture in [false, true] {
                    for focused in [false, true] {
                        XCTAssertEqual(
                            RightClickDisposition.decide(
                                optionHeld: option, captureEnabled: capture, paneIsFocused: focused,
                                rearrangeActive: true, mode: mode
                            ),
                            .suppressed,
                            "mode=\(mode) option=\(option) capture=\(capture) focused=\(focused)"
                        )
                    }
                }
            }
        }
    }
}
