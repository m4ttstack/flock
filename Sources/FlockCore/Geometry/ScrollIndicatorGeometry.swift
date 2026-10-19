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

    /// The thumb for a scroll view measured in points, `nil` when the content
    /// fits. A bounce past either end leaves the thumb at that end.
    public static func thumb(
        offset: CGFloat, content: CGFloat, visible: CGFloat, trackLength: CGFloat, minimumLength: CGFloat = 15
    ) -> Thumb? {
        guard content > visible, visible > 0, trackLength > 0 else { return nil }
        let length = min(trackLength, max(minimumLength, trackLength * visible / content))
        let progress = min(1, max(0, offset / (content - visible)))
        return Thumb(offset: (trackLength - length) * progress, length: length)
    }

    /// The content offset that puts `thumb`'s top at `thumbOffset`, for a
    /// thumb that can be dragged.
    public static func contentOffset(
        forThumbAt thumbOffset: CGFloat, thumb: Thumb, content: CGFloat, visible: CGFloat, trackLength: CGFloat
    ) -> CGFloat {
        let travel = trackLength - thumb.length
        guard travel > 0 else { return 0 }
        return min(1, max(0, thumbOffset / travel)) * max(0, content - visible)
    }
}
