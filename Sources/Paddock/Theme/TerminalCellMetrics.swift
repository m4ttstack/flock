import CoreGraphics
import CoreText
import Foundation
import PaddockCore

/// The terminal cell libghostty will use for `TerminalFont.face` at a font
/// size, computed the way ghostty computes it (`font/face/coretext.zig`
/// `getMetrics` and `font/Metrics.zig` `calc`): the cell width is the widest
/// horizontal advance over printable ASCII, the cell height is the line
/// height from the font's `hhea` table (or OS/2 typo metrics when the font
/// asks for them), each in pixels at `points * scale`, rounded to whole
/// pixels, then returned in points. Reproducing the derivation is what lets
/// the canvas derive a pane's whole-cell grid, and size its surface to
/// exactly that many cells, BEFORE the font is applied;
/// `GhosttySession.verifyExpectedGrid` checks the live surface agrees
/// afterwards. Rounding to whole pixels also makes every cell an exact
/// multiple of 1/scale, so a grid of them never lands the surface's far edge
/// on a fractional device pixel.
enum TerminalCellMetrics {
    private struct Key: Hashable {
        let points: Double
        let scale: CGFloat
    }

    nonisolated(unsafe) private static var cache: [Key: CGSize] = [:]
    private static let cacheLock = NSLock()

    static func cell(fontSize points: Double, scale: CGFloat) -> CGSize {
        let key = Key(points: points, scale: scale)
        cacheLock.lock()
        if let cached = cache[key] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()
        let measured = measure(points: points, scale: scale)
        cacheLock.lock()
        cache[key] = measured
        cacheLock.unlock()
        return measured
    }

    private static func measure(points: Double, scale: CGFloat) -> CGSize {
        let pixels = points * Double(scale)
        let font = CTFontCreateWithName(TerminalFont.face as CFString, pixels, nil)
        let widthPx = maxASCIIAdvance(font).rounded()
        let heightPx = lineHeight(font, pixels: pixels).rounded()
        return CGSize(width: widthPx / scale, height: heightPx / scale)
    }

    private static func maxASCIIAdvance(_ font: CTFont) -> Double {
        let characters = (32..<127).map { UniChar($0) }
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count)
        var advances = [CGSize](repeating: .zero, count: glyphs.count)
        CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, glyphs.count)
        return Double(advances.map(\.width).max() ?? 0)
    }

    /// `hhea` ascender - descender + lineGap scaled by pixels-per-unit, the
    /// same branch ghostty takes for a font whose OS/2 table does not set
    /// USE_TYPO_METRICS; when it does, the OS/2 sTypo values win instead.
    /// Falls back to CoreText's own ascent/descent/leading if the tables
    /// cannot be read.
    private static func lineHeight(_ font: CTFont, pixels: Double) -> Double {
        let unitsPerEm = Double(CTFontGetUnitsPerEm(font))
        guard unitsPerEm > 0 else { return coreTextLineHeight(font) }
        let pxPerUnit = pixels / unitsPerEm

        if let os2 = table(font, CTFontTableTag(kCTFontTableOS2)), os2.count >= 74, os2.uint16(at: 62) & (1 << 7) != 0 {
            let ascender = Double(os2.int16(at: 68))
            let descender = Double(os2.int16(at: 70))
            let lineGap = Double(os2.int16(at: 72))
            return (ascender - descender + lineGap) * pxPerUnit
        }
        if let hhea = table(font, CTFontTableTag(kCTFontTableHhea)), hhea.count >= 10 {
            let ascender = Double(hhea.int16(at: 4))
            let descender = Double(hhea.int16(at: 6))
            let lineGap = Double(hhea.int16(at: 8))
            if ascender != 0 || descender != 0 {
                return (ascender - descender + lineGap) * pxPerUnit
            }
        }
        return coreTextLineHeight(font)
    }

    private static func coreTextLineHeight(_ font: CTFont) -> Double {
        Double(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font))
    }

    private static func table(_ font: CTFont, _ tag: CTFontTableTag) -> Data? {
        guard let data = CTFontCopyTable(font, tag, []) else { return nil }
        return data as Data
    }
}

private extension Data {
    func uint16(at offset: Int) -> UInt16 {
        UInt16(self[startIndex + offset]) << 8 | UInt16(self[startIndex + offset + 1])
    }

    func int16(at offset: Int) -> Int16 {
        Int16(bitPattern: uint16(at: offset))
    }
}
