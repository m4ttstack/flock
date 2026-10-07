import CoreGraphics

/// The four corner radii the chrome uses, chosen by what a shape is rather
/// than which view draws it. A shape nested in another is never rounder than
/// the one around it.
public enum ChromeRadius {
    /// Badges, checkboxes and chips set inside text.
    public static let tiny: CGFloat = 3
    /// Buttons, fields, rows and chips.
    public static let control: CGFloat = 5
    /// Terminal panes, cards, thumbnails, tab tops and tips.
    public static let surface: CGFloat = 7
    /// Lanes, groups, islands, popovers, palettes and modals.
    public static let container: CGFloat = 10
}
