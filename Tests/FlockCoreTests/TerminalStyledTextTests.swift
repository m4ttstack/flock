import Foundation
import XCTest
@testable import FlockCore

final class TerminalStyledTextTests: XCTestCase {
    private func row(_ ansi: String) -> StyledRow {
        let rows = TerminalStyledText.rows(of: ansi)
        XCTAssertEqual(rows.count, 1, "expected one row from \(ansi.debugDescription)")
        return rows.first ?? StyledRow(runs: [])
    }

    func testPlainTextIsOneUnstyledRunPerRow() {
        let rows = TerminalStyledText.rows(of: "one\ntwo")
        XCTAssertEqual(rows, [StyledRow(plain: "one"), StyledRow(plain: "two")])
        XCTAssertEqual(rows.map(\.runs.first?.style), [.plain, .plain])
    }

    /// herdr's VT formatter ends each row with `\r\n`.
    func testCarriageReturnsNeverReachTheText() {
        XCTAssertEqual(TerminalStyledText.rows(of: "one\r\ntwo\r\n").map(\.text), ["one", "two", ""])
    }

    func testBasicAttributesAndReset() {
        let styled = row("\u{1B}[1mbold\u{1B}[0m \u{1B}[2;3;4mfaint\u{1B}[22;23;24m \u{1B}[7;9minv\u{1B}[27;29mend")
        XCTAssertEqual(styled.text, "bold faint invend")
        XCTAssertEqual(styled.runs.map(\.text), ["bold", " ", "faint", " ", "inv", "end"])
        XCTAssertEqual(styled.runs[0].style, TerminalStyle(bold: true))
        XCTAssertEqual(styled.runs[1].style, .plain)
        XCTAssertEqual(styled.runs[2].style, TerminalStyle(dim: true, italic: true, underline: true))
        XCTAssertEqual(styled.runs[3].style, .plain)
        XCTAssertEqual(styled.runs[4].style, TerminalStyle(inverse: true, strikethrough: true))
        XCTAssertEqual(styled.runs[5].style, .plain)
    }

    /// An empty SGR is a reset, as `ESC [ 0 m` is.
    func testAnEmptySGRResets() {
        let styled = row("\u{1B}[31mred\u{1B}[mplain")
        XCTAssertEqual(styled.runs.map(\.style), [TerminalStyle(foreground: .indexed(1)), .plain])
    }

    func testTheSixteenIndexedColoursInBothSlots() {
        let styled = row("\u{1B}[32;41ma\u{1B}[97;104mb\u{1B}[39;49mc")
        XCTAssertEqual(styled.runs.map(\.style), [
            TerminalStyle(foreground: .indexed(2), background: .indexed(1)),
            TerminalStyle(foreground: .indexed(15), background: .indexed(12)),
            .plain,
        ])
    }

    func testTwoHundredFiftySixColourAndTruecolourInBothSeparatorForms() {
        let styled = row(
            "\u{1B}[38;5;208ma\u{1B}[48;5;240mb\u{1B}[0;38;2;10;20;30mc\u{1B}[0;48:2::1:2:3md\u{1B}[0;38:5:3me\u{1B}[0;38:2:4:5:6mf"
        )
        XCTAssertEqual(styled.runs.map(\.style), [
            TerminalStyle(foreground: .indexed(208)),
            TerminalStyle(foreground: .indexed(208), background: .indexed(240)),
            TerminalStyle(foreground: .rgb(red: 10, green: 20, blue: 30)),
            TerminalStyle(background: .rgb(red: 1, green: 2, blue: 3)),
            TerminalStyle(foreground: .indexed(3)),
            TerminalStyle(foreground: .rgb(red: 4, green: 5, blue: 6)),
        ])
    }

    /// An extended colour consumes its own fields, so what follows it in the
    /// same SGR still applies.
    func testFieldsAfterAnExtendedColourStillApply() {
        let styled = row("\u{1B}[38;2;1;2;3;1;48;5;4mx")
        XCTAssertEqual(styled.runs.first?.style, TerminalStyle(
            foreground: .rgb(red: 1, green: 2, blue: 3), background: .indexed(4), bold: true
        ))
    }

    /// ghostty's formatter writes `4:3` for a curly underline and `58;...`
    /// for its colour; neither is a colour for the text.
    func testUnderlineStylesAndUnderlineColour() {
        let styled = row("\u{1B}[4:3;58;2;9;9;9ma\u{1B}[4:0mb\u{1B}[21mc")
        XCTAssertEqual(styled.runs.map(\.style), [
            TerminalStyle(underline: true), .plain, TerminalStyle(underline: true),
        ])
    }

    /// `ESC [ > 4 ; 2 m` is xterm's modifyOtherKeys, not SGR.
    func testAPrivateMarkerSGRIsNotStyling() {
        XCTAssertEqual(row("\u{1B}[>4;2mtext").runs.map(\.style), [.plain])
    }

    func testNonSGREscapesLeaveNothingBehind() {
        let screen = [
            "\u{1B}[2J\u{1B}[H\u{1B}[?25l\u{1B}[3;12Hhead",
            "\u{1B}]0;a title\u{07}osc-bel",
            "\u{1B}]8;;https://acme.example\u{1B}\\link\u{1B}]8;;\u{1B}\\",
            "\u{1B}(B\u{1B}=\u{1B}7saved\u{1B}8",
            "\u{1B}P1$r0m\u{1B}\\dcs\u{1B}_apc\u{1B}\\",
            "\u{9B}31mc1\u{9D}2;t\u{07}",
        ].joined(separator: "\n")
        let rows = TerminalStyledText.rows(of: screen)
        XCTAssertEqual(rows.map(\.text), ["head", "osc-bel", "link", "saved", "dcs", "c1"])
        XCTAssertFalse(rows.flatMap(\.runs).contains { $0.text.unicodeScalars.contains { $0.value < 0x20 || (0x7F...0x9F).contains($0.value) } })
        XCTAssertEqual(rows[5].runs.first?.style, TerminalStyle(foreground: .indexed(1)))
    }

    /// The formatter writes a style once and leaves it set across row breaks.
    func testStyleCarriesAcrossRows() {
        let rows = TerminalStyledText.rows(of: "\u{1B}[34mone\r\ntwo\u{1B}[0m")
        XCTAssertEqual(rows.map { $0.runs.map(\.style) }, [
            [TerminalStyle(foreground: .indexed(4))], [TerminalStyle(foreground: .indexed(4))],
        ])
    }

    /// Trailing blanks pad a row out and are cut from both its text and its
    /// runs, unless they paint a background: then they are a bar the card
    /// draws, though the text still ends at the last glyph.
    func testTrailingBlanksStayOnlyWhenTheyPaint() {
        let padded = row("ok\u{1B}[1m   \u{1B}[0m\t ")
        XCTAssertEqual(padded.runs, [StyledRun(text: "ok", style: .plain)])
        let bar = row("\u{1B}[44m title   \u{1B}[0m   ")
        XCTAssertEqual(bar.text, " title")
        XCTAssertEqual(bar.runs, [StyledRun(text: " title   ", style: TerminalStyle(background: .indexed(4)))])
        XCTAssertEqual(bar.columns, 9)
    }

    func testColumnsCountWideCharactersTwice() {
        XCTAssertEqual(StyledRow(plain: "ab").columns, 2)
        XCTAssertEqual(StyledRow(plain: "a界").columns, 3)
        XCTAssertEqual(StyledRow(plain: "──").columns, 2)
    }

    func testThePaletteTakesItsFirstSixteenSlotsFromTheTheme() {
        let ansi = (0..<16).map { GhosttyThemeColor(red: UInt8($0), green: 100, blue: 200) }
        XCTAssertEqual(TerminalPalette.rgb(of: .indexed(0), ansi: ansi), ansi[0])
        XCTAssertEqual(TerminalPalette.rgb(of: .indexed(13), ansi: ansi), ansi[13])
    }

    func testTheCubeAndTheGreyRamp() {
        let ansi = Array(repeating: GhosttyThemeColor(red: 1, green: 1, blue: 1), count: 16)
        XCTAssertEqual(TerminalPalette.rgb(of: .indexed(16), ansi: ansi), GhosttyThemeColor(red: 0, green: 0, blue: 0))
        XCTAssertEqual(TerminalPalette.rgb(of: .indexed(196), ansi: ansi), GhosttyThemeColor(red: 255, green: 0, blue: 0))
        XCTAssertEqual(TerminalPalette.rgb(of: .indexed(208), ansi: ansi), GhosttyThemeColor(red: 255, green: 135, blue: 0))
        XCTAssertEqual(TerminalPalette.rgb(of: .indexed(231), ansi: ansi), GhosttyThemeColor(red: 255, green: 255, blue: 255))
        XCTAssertEqual(TerminalPalette.rgb(of: .indexed(232), ansi: ansi), GhosttyThemeColor(red: 8, green: 8, blue: 8))
        XCTAssertEqual(TerminalPalette.rgb(of: .indexed(255), ansi: ansi), GhosttyThemeColor(red: 238, green: 238, blue: 238))
        XCTAssertEqual(TerminalPalette.rgb(of: .rgb(red: 7, green: 8, blue: 9), ansi: ansi), GhosttyThemeColor(red: 7, green: 8, blue: 9))
    }
}

/// The tail's rules over a styled read: the same rows survive as a plain read
/// keeps, each with its styling, and the copy is plain text.
final class PaneTailStyledTests: XCTestCase {
    func testAStyledScreenKeepsThePlainScreensRowsAndItsOwnStyling() {
        let rule = String(repeating: "─", count: 20)
        let styled = [
            "\u{1B}[0m",
            "\u{1B}[1;32m(pass)\u{1B}[0m allocates the first free port",
            "",
            "",
            "\u{1B}[31m(fail)\u{1B}[0m refuses a port   ",
            "\u{1B}[2m\(rule)\u{1B}[0m",
            "\u{1B}[1m❯\u{1B}[0m ",
            "\u{1B}[2m\(rule)\u{1B}[0m",
            "  \u{1B}[38;5;244m? for shortcuts\u{1B}[0m",
            "",
        ].joined(separator: "\r\n")
        let plain = styled.replacingOccurrences(of: "\u{1B}[0m", with: "")
            .replacingOccurrences(of: "\u{1B}[1;32m", with: "").replacingOccurrences(of: "\u{1B}[31m", with: "")
            .replacingOccurrences(of: "\u{1B}[2m", with: "").replacingOccurrences(of: "\u{1B}[1m", with: "")
            .replacingOccurrences(of: "\u{1B}[38;5;244m", with: "").replacingOccurrences(of: "\r", with: "")
        let tail = PaneTailPolicy.make(from: styled)
        XCTAssertEqual(tail.lines, PaneTailPolicy.make(from: plain).lines)
        XCTAssertEqual(tail.lines, ["(pass) allocates the first free port", "", "(fail) refuses a port"])
        XCTAssertEqual(tail.text, "(pass) allocates the first free port\n\n(fail) refuses a port")
        XCTAssertEqual(tail.rows[0].runs.first, StyledRun(text: "(pass)", style: TerminalStyle(foreground: .indexed(2), bold: true)))
        XCTAssertEqual(tail.rows[2].runs.first, StyledRun(text: "(fail)", style: TerminalStyle(foreground: .indexed(1))))
    }
}
