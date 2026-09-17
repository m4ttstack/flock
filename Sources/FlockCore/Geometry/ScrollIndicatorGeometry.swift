import CoreGraphics

/// The thumb of a pane's scroll indicator, derived purely from herdr's own
/// scroll state: the indicator mirrors the pane's shared viewport and never
/// drives it.
public enum ScrollIndicatorGeometry {
    public struct Thumb: Equatable, Sendable {
        /// Distance from the top of the track to the thumb's top.
        public let offset: CGFloat
        public let length: CGFloat
    }

    /// `nil` when nothing should show: the viewport is at its tail, there
    /// is no scrollback, or the track has no length. Otherwise the thumb's
    /// length is the viewport's share of (scrollback + viewport) rows,
    /// floored at `minimumLength`, and its offset places the viewport's
    /// position within the remaining travel, top meaning fully scrolled up.
    public static func thumb(for scroll: ScrollInfo, trackLength: CGFloat, minimumLength: CGFloat = 15) -> Thumb? {
        guard scroll.offsetFromBottom > 0, scroll.maxOffsetFromBottom > 0, scroll.viewportRows > 0, trackLength > 0 else {
            return nil
        }
        let total = CGFloat(scroll.maxOffsetFromBottom + scroll.viewportRows)
        let share = CGFloat(scroll.viewportRows) / total
        let length = min(trackLength, max(minimumLength, trackLength * share))
        let offsetFromBottom = min(scroll.offsetFromBottom, scroll.maxOffsetFromBottom)
        let fromTop = CGFloat(scroll.maxOffsetFromBottom - offsetFromBottom) / CGFloat(scroll.maxOffsetFromBottom)
        return Thumb(offset: (trackLength - length) * fromTop, length: length)
    }
}
