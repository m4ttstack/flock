import CoreGraphics

/// Where the tab strip's new-tab hover affordance sits: right past the last
/// tab's own gap, sized like an empty tab rather than stretched to fill
/// whatever room is left. Mirrors `DropZones`: a run too short to hold one
/// yields no affordance at all.
public enum NewTabAffordance {
    /// An empty tab's own width: the affordance previews the shape a new tab
    /// takes before it has a title, which is the one width `TabWidth.fitting`
    /// ever returns for that.
    public static let width: CGFloat = TabWidth.minimum

    /// `tabsEnd` is every current tab's own width summed, gaps between them
    /// and the strip's own leading inset included, all measured from the
    /// strip's own origin. `viewportWidth` is the strip's visible run ahead
    /// of any scroll a full strip has already earned: an affordance only a
    /// scroll could reach is not "the empty space to the right of the last
    /// tab," so a strip filled to its own visible edge draws none at all.
    public static func frame(tabsEnd: CGFloat, gap: CGFloat, viewportWidth: CGFloat, height: CGFloat) -> CGRect? {
        let x = tabsEnd + gap
        guard x + width <= viewportWidth else { return nil }
        return CGRect(x: x, y: 0, width: width, height: height)
    }
}
