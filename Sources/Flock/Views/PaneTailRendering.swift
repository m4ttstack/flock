import AppKit
import CoreText
import FlockCore
import SwiftUI

/// How the hover card draws a pane's tail: in the pane's own colours, one
/// screen row to one line, never wrapped, so the card reads as a miniature of
/// the pane rather than a reflow of it.
enum PaneTailRendering {
    /// ghostty's own default `faint-opacity`.
    static let dimOpacity: Double = 0.5

    /// The largest size, up to the card's own, at which a row `columns` cells
    /// wide fits `width`.
    static func fontSize(columns: Int, width: CGFloat) -> CGFloat {
        let maxSize = ChromeType.hoverCardTailMaxSize
        guard columns > 0, width > 0, advancePerPoint > 0 else { return maxSize }
        let fitted = width / (CGFloat(columns) * advancePerPoint)
        // Rounded down, so a row that fits on paper never spills by a sliver.
        let stepped = (fitted * 10).rounded(.down) / 10
        return min(maxSize, max(ChromeType.hoverCardTailMinSize, stepped))
    }

    /// The terminal face's cell width per point of size; a monospaced face's
    /// advance scales linearly with its size.
    static let advancePerPoint: CGFloat = {
        let reference: CGFloat = 100
        let font = CTFontCreateWithName(TerminalFont.face as CFString, reference, nil)
        var character = UniChar(("M" as Unicode.Scalar).value)
        var glyph = CGGlyph()
        guard CTFontGetGlyphsForCharacters(font, &character, &glyph, 1) else { return 0.6 }
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
        return advance.width / reference
    }()

    static func attributed(_ row: StyledRow, size: CGFloat, palette: PaneTailPalette) -> AttributedString {
        var line = AttributedString()
        for run in row.runs {
            var part = AttributedString(run.text)
            let style = run.style
            var font = ChromeType.hoverCardTail(size: size)
            if style.bold { font = font.bold() }
            if style.italic { font = font.italic() }
            part.font = font
            var foreground = style.foreground.map(palette.color) ?? palette.foreground
            var background = style.background.map(palette.color)
            if style.inverse {
                let swapped = background ?? palette.ground
                background = foreground
                foreground = swapped
            }
            if style.dim { foreground = foreground.opacity(dimOpacity) }
            part.foregroundColor = style.invisible ? .clear : foreground
            if let background { part.backgroundColor = background }
            if style.underline { part.underlineStyle = .single }
            if style.strikethrough { part.strikethroughStyle = .single }
            line += part
        }
        return line
    }
}

/// A theme's terminal colours, resolved once per draw of the tail.
struct PaneTailPalette {
    let ansi: [GhosttyThemeColor]
    let foreground: Color
    /// What an inverse cell with no background of its own paints with.
    let ground: Color

    init(theme: Theme) {
        let colors = theme.ghosttyThemeColors()
        ansi = colors.ansi
        foreground = Color(nsColor: NSColor(colors.foreground))
        ground = Color(nsColor: NSColor(colors.background))
    }

    func color(_ color: TerminalColor) -> Color {
        Color(nsColor: NSColor(TerminalPalette.rgb(of: color, ansi: ansi)))
    }
}
