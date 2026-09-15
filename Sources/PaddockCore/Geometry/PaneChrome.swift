import CoreGraphics

/// A pane box's own chrome around its terminal surface: padding on every side
/// and a title row above the surface. Every value is a whole point, which is
/// what keeps the surface's origin on the device-pixel grid the box was
/// snapped to.
public enum PaneChrome {
    public static let verticalPadding: CGFloat = 10
    public static let horizontalPadding: CGFloat = 13
    public static let titleRowHeight: CGFloat = 14
    public static let titleGap: CGFloat = 4
    /// Every rounded shape drawn over or beside a box (drop preview, landing
    /// flash, ghost, toasts) takes this too, so an overlay's corners trace
    /// the box it lands on.
    public static let cornerRadius: CGFloat = 3

    /// From the box's top edge down to the first terminal row. This band is
    /// also the pane's at-rest drag handle, so it costs no terminal rows.
    public static var contentTop: CGFloat { verticalPadding + titleRowHeight + titleGap }

    /// Everything a box holds besides its surface, per axis: what is taken off
    /// a box before deriving its whole-cell grid.
    public static var size: CGSize {
        CGSize(width: horizontalPadding * 2, height: contentTop + verticalPadding)
    }
}
