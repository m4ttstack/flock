import Foundation

/// The deep-history overlay's per-row height: the surface's real
/// `cell_height_px` (from `ghostty_surface_size`) converted to points via the
/// hosting window's actual backing scale. Pure and separate from any font
/// metric on purpose -- ghostty rounds its cell height to a whole DEVICE
/// pixel before ever returning it (`Vendor/ghostty/src/font/Metrics.zig`:
/// `cell_height = @round(face_height)`, stored `u32`), while a font's own
/// natural line height (`NSFont.ascender - .descender + .leading`) is
/// unrounded and can land on EITHER side of that pixel-quantized cell -- at
/// paddock's default 13pt Menlo, the cell (15.0pt @2x) is actually SHORTER
/// than the font's natural line height (15.1328pt), so adding `.lineSpacing`
/// on top of the font's own height can only ever grow the pitch, never
/// shrink it back down to the real cell height. The overlay instead pins
/// each row's CONTAINER to this exact value (`HistoryBrowseView`'s per-row
/// `.frame(height:)`), so the pitch is exact regardless of which side of the
/// cell the font's own metrics happen to fall on.
public enum TerminalRowPitch {
    /// `cellHeightPx` in real device pixels, `scale` the hosting window's
    /// `backingScaleFactor` (never assumed -- read live, per view).
    public static func points(cellHeightPx: Int, scale: Double) -> Double {
        guard scale > 0 else { return Double(cellHeightPx) }
        return Double(cellHeightPx) / scale
    }

    /// The exact height `rowCount` stacked rows occupy at zero inter-row
    /// spacing -- `rowCount * points(...)`, never a separately-rounded sum,
    /// so N rows can never drift from N times one row's own pitch.
    public static func totalHeight(rowCount: Int, cellHeightPx: Int, scale: Double) -> Double {
        Double(rowCount) * points(cellHeightPx: cellHeightPx, scale: scale)
    }
}
