import CoreGraphics

/// Whether the title bar's centred title fits between what sits at its two
/// ends: the view tabs after the window buttons, and the notices and key
/// hints at the right. The title stays centred on the bar, so it hides
/// rather than sliding aside when either end would reach it.
public enum TitleBarFit {
    public static func showsTitle(
        barWidth: CGFloat, titleWidth: CGFloat, leadingEdge: CGFloat, trailingWidth: CGFloat, gap: CGFloat
    ) -> Bool {
        let titleMinX = (barWidth - titleWidth) / 2
        let titleMaxX = titleMinX + titleWidth
        return titleMinX >= leadingEdge + gap && titleMaxX <= barWidth - trailingWidth - gap
    }

    /// Names are all or none: a strip that would not fit named between the
    /// view tabs and the notices draws every cell as its icon alone.
    public static func showsNames(
        barWidth: CGFloat, leadingEdge: CGFloat, noticesWidth: CGFloat, namedStripWidth: CGFloat, gap: CGFloat
    ) -> Bool {
        barWidth - leadingEdge - noticesWidth - namedStripWidth >= gap
    }
}
