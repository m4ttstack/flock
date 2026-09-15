import XCTest
@testable import PaddockCore

/// Pins the hex output for three named themes' literal RGB values (as
/// transcribed from `Sources/Paddock/Theme/Theme.swift` at the time this test
/// was written), so a change to the ANSI-slot derivation or the hex
/// formatting shows up here rather than only in a rendered pane. The
/// `Theme -> GhosttyThemeColors` mapping itself lives in the app target
/// (it needs `NSColor` to read a `SwiftUI.Color` back into bytes) and is not
/// reachable from this target; what is pinned here is `GhosttyThemeConfig`'s
/// pure text generation given those bytes.
final class GhosttyThemeConfigTests: XCTestCase {
    private func color(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> GhosttyThemeColor {
        GhosttyThemeColor(red: r, green: g, blue: b)
    }

    /// Tokyo Night: background/foreground plus all 16 ANSI slots, derived as
    /// black/white -> surface1/subtext0, bright-black/bright-white ->
    /// overlay0/text, red/green/yellow/blue verbatim, magenta/cyan ->
    /// mauve/teal, every bright slot reusing its normal counterpart.
    func testTokyoNightExactHexLines() {
        let colors = GhosttyThemeColors(
            background: color(0x19, 0x1a, 0x22),
            foreground: color(0xc0, 0xca, 0xf5),
            ansi: [
                color(0x41, 0x48, 0x68), color(0xf7, 0x76, 0x8e), color(0x9e, 0xce, 0x6a), color(0xe0, 0xaf, 0x68),
                color(0x7a, 0xa2, 0xf7), color(0xbb, 0x9a, 0xf7), color(0x7d, 0xcf, 0xff), color(0xa9, 0xb1, 0xd6),
                color(0x56, 0x5f, 0x89), color(0xf7, 0x76, 0x8e), color(0x9e, 0xce, 0x6a), color(0xe0, 0xaf, 0x68),
                color(0x7a, 0xa2, 0xf7), color(0xbb, 0x9a, 0xf7), color(0x7d, 0xcf, 0xff), color(0xc0, 0xca, 0xf5),
            ]
        )
        XCTAssertEqual(GhosttyThemeConfig.configText(colors: colors), """
        background = #191a22
        foreground = #c0caf5
        palette = 0=#414868
        palette = 1=#f7768e
        palette = 2=#9ece6a
        palette = 3=#e0af68
        palette = 4=#7aa2f7
        palette = 5=#bb9af7
        palette = 6=#7dcfff
        palette = 7=#a9b1d6
        palette = 8=#565f89
        palette = 9=#f7768e
        palette = 10=#9ece6a
        palette = 11=#e0af68
        palette = 12=#7aa2f7
        palette = 13=#bb9af7
        palette = 14=#7dcfff
        palette = 15=#c0caf5

        """)
    }

    /// Catppuccin (Mocha), herdr's default.
    func testCatppuccinExactHexLines() {
        let colors = GhosttyThemeColors(
            background: color(0x17, 0x17, 0x21),
            foreground: color(0xcd, 0xd6, 0xf4),
            ansi: [
                color(0x45, 0x47, 0x5a), color(0xf3, 0x8b, 0xa8), color(0xa6, 0xe3, 0xa1), color(0xf9, 0xe2, 0xaf),
                color(0x89, 0xb4, 0xfa), color(0xcb, 0xa6, 0xf7), color(0x94, 0xe2, 0xd5), color(0xa6, 0xad, 0xc8),
                color(0x6c, 0x70, 0x86), color(0xf3, 0x8b, 0xa8), color(0xa6, 0xe3, 0xa1), color(0xf9, 0xe2, 0xaf),
                color(0x89, 0xb4, 0xfa), color(0xcb, 0xa6, 0xf7), color(0x94, 0xe2, 0xd5), color(0xcd, 0xd6, 0xf4),
            ]
        )
        XCTAssertEqual(GhosttyThemeConfig.configText(colors: colors), """
        background = #171721
        foreground = #cdd6f4
        palette = 0=#45475a
        palette = 1=#f38ba8
        palette = 2=#a6e3a1
        palette = 3=#f9e2af
        palette = 4=#89b4fa
        palette = 5=#cba6f7
        palette = 6=#94e2d5
        palette = 7=#a6adc8
        palette = 8=#6c7086
        palette = 9=#f38ba8
        palette = 10=#a6e3a1
        palette = 11=#f9e2af
        palette = 12=#89b4fa
        palette = 13=#cba6f7
        palette = 14=#94e2d5
        palette = 15=#cdd6f4

        """)
    }

    /// Dracula: `blue` and `teal` share one literal RGB tuple in `Theme`, so
    /// ANSI blue and cyan legitimately collapse to the same hex here -- that
    /// is Theme's own data, not a mapping bug.
    func testDraculaExactHexLines() {
        let colors = GhosttyThemeColors(
            background: color(0x27, 0x29, 0x32),
            foreground: color(0xf8, 0xf8, 0xf2),
            ansi: [
                color(0x62, 0x72, 0xa4), color(0xff, 0x55, 0x55), color(0x50, 0xfa, 0x7b), color(0xf1, 0xfa, 0x8c),
                color(0x8b, 0xe9, 0xfd), color(0xff, 0x79, 0xc6), color(0x8b, 0xe9, 0xfd), color(0xd2, 0xd2, 0xdc),
                color(0x62, 0x72, 0xa4), color(0xff, 0x55, 0x55), color(0x50, 0xfa, 0x7b), color(0xf1, 0xfa, 0x8c),
                color(0x8b, 0xe9, 0xfd), color(0xff, 0x79, 0xc6), color(0x8b, 0xe9, 0xfd), color(0xf8, 0xf8, 0xf2),
            ]
        )
        XCTAssertEqual(GhosttyThemeConfig.configText(colors: colors), """
        background = #272932
        foreground = #f8f8f2
        palette = 0=#6272a4
        palette = 1=#ff5555
        palette = 2=#50fa7b
        palette = 3=#f1fa8c
        palette = 4=#8be9fd
        palette = 5=#ff79c6
        palette = 6=#8be9fd
        palette = 7=#d2d2dc
        palette = 8=#6272a4
        palette = 9=#ff5555
        palette = 10=#50fa7b
        palette = 11=#f1fa8c
        palette = 12=#8be9fd
        palette = 13=#ff79c6
        palette = 14=#8be9fd
        palette = 15=#f8f8f2

        """)
    }

    func testConfigTextWithCommandAppendsShellEscapedCommandLine() {
        let colors = GhosttyThemeColors(
            background: color(0, 0, 0),
            foreground: color(255, 255, 255),
            ansi: Array(repeating: color(0, 0, 0), count: 16)
        )
        let text = GhosttyThemeConfig.configText(
            colors: colors,
            commandArgv: ["/path/to/Paddock", "--bridge", "w1:p1", "--socket", "/tmp/a b.sock"],
            fontFamily: "Menlo", fontSizePoints: 13.0
        )
        XCTAssertTrue(text.hasSuffix(
            "command = shell:'/path/to/Paddock' '--bridge' 'w1:p1' '--socket' '/tmp/a b.sock'\n"
        ))
    }

    /// The scratch config zeroes libghostty's default 2px grid padding: the
    /// mouse-to-cell conversion divides the raw view point from origin 0, so
    /// any padding would shift every click toward the previous cell.
    func testConfigTextWithCommandZeroesWindowPadding() {
        let colors = GhosttyThemeColors(
            background: color(0, 0, 0),
            foreground: color(255, 255, 255),
            ansi: Array(repeating: color(0, 0, 0), count: 16)
        )
        let text = GhosttyThemeConfig.configText(
            colors: colors, commandArgv: ["/path/to/Paddock"], fontFamily: "Menlo", fontSizePoints: 13.0
        )
        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines.contains("window-padding-x = 0"), "missing window-padding-x = 0 in:\n\(text)")
        XCTAssertTrue(lines.contains("window-padding-y = 0"), "missing window-padding-y = 0 in:\n\(text)")
    }

    /// One truth for both the scratch (surface-creation) config and the live
    /// text-size update path, since both route through this one function:
    /// pinned per size (compact/regular/large's actual point values), with
    /// regular (13pt) as the default paddock's `TerminalTextSize` starts at.
    func testConfigTextIncludesFontFamilyAndSizeLinesPerSize() {
        let colors = GhosttyThemeColors(
            background: color(0, 0, 0),
            foreground: color(255, 255, 255),
            ansi: Array(repeating: color(0, 0, 0), count: 16)
        )
        for points in [11.0, 13.0, 15.0] {
            let text = GhosttyThemeConfig.configText(
                colors: colors, commandArgv: ["/path/to/Paddock"], fontFamily: "Menlo", fontSizePoints: points
            )
            let lines = text.split(separator: "\n").map(String.init)
            XCTAssertTrue(lines.contains("font-family = Menlo"), "missing font-family line at \(points)pt in:\n\(text)")
            XCTAssertTrue(lines.contains("font-size = \(Int(points))"), "missing font-size = \(Int(points)) in:\n\(text)")
        }
    }

    /// The fit steps in half points; ghostty's `font-size` is an `f32`, so a
    /// half-point size goes out as a plain decimal and a whole one stays a
    /// bare integer.
    func testConfigTextWritesHalfPointFontSizesAsDecimals() {
        let colors = GhosttyThemeColors(
            background: color(0, 0, 0),
            foreground: color(255, 255, 255),
            ansi: Array(repeating: color(0, 0, 0), count: 16)
        )
        let text = GhosttyThemeConfig.configText(
            colors: colors, commandArgv: ["/path/to/Paddock"], fontFamily: "Menlo", fontSizePoints: 12.5
        )
        XCTAssertTrue(text.split(separator: "\n").contains("font-size = 12.5"), text)
    }

    func testShellEscapedDoublesEmbeddedSingleQuote() {
        XCTAssertEqual("it's".shellEscaped, "'it'\\''s'")
    }

    func testGhosttyThemeColorsRequiresSixteenAnsiSlots() {
        // `precondition` traps rather than throwing, so this only documents
        // the contract; it is not exercised as a crashing test.
        XCTAssertEqual(GhosttyThemeColors(
            background: color(0, 0, 0), foreground: color(1, 1, 1),
            ansi: Array(repeating: color(2, 2, 2), count: 16)
        ).ansi.count, 16)
    }

    /// A family given only as `font-family` leaves ghostty to synthesize
    /// bold by smearing the regular face, which is a pixel heavier and
    /// softer than the family's real bold member.
    func testEveryStyleNamesTheFamilySoNoneIsSynthesized() {
        let colors = GhosttyThemeColors(
            background: color(0x19, 0x1a, 0x22),
            foreground: color(0xc0, 0xca, 0xf5),
            ansi: (0..<16).map { _ in color(0x41, 0x48, 0x68) }
        )
        let text = GhosttyThemeConfig.configText(
            colors: colors, commandArgv: ["/bin/zsh"], fontFamily: "JetBrainsMono Nerd Font",
            fontSizePoints: 13
        )
        for key in ["font-family", "font-family-bold", "font-family-italic", "font-family-bold-italic"] {
            XCTAssertTrue(
                text.contains("\(key) = JetBrainsMono Nerd Font\n"),
                "\(key) is not named, so ghostty synthesizes that style"
            )
        }
    }

}
