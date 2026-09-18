import CoreGraphics

/// How wide a tab in the window strip is drawn: whatever its title needs,
/// inside bounds neither end of the strip can give up. A tab narrower than
/// `minimum` stops reading as a tab and leaves the strip ragged under short
/// names; a tab past `maximum` spends the strip on one title, so a longer one
/// truncates there instead.
public enum TabWidth {
    public static let minimum: CGFloat = 100
    public static let maximum: CGFloat = 200

    /// `titleWidth` is the label measured in the face it is drawn in; the rest
    /// is what the tab lays out beside it. `trailingSlot` is the one place the
    /// status dot and the hover close are drawn, so it is the wider of them
    /// rather than whichever is showing.
    ///
    /// Rounded up to a whole point: measured text lands on fractions, the
    /// chrome's surfaces are drawn on the pixel grid, and one fractional tab
    /// carries every tab after it off that grid. Up rather than to nearest,
    /// because a title rounded down is a title truncated.
    public static func fitting(
        titleWidth: CGFloat, horizontalPadding: CGFloat, labelDotGap: CGFloat, trailingSlot: CGFloat
    ) -> CGFloat {
        let fitted = (horizontalPadding * 2 + titleWidth + labelDotGap + trailingSlot).rounded(.up)
        return min(max(fitted, minimum), maximum)
    }
}
