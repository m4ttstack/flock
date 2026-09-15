import CoreGraphics

/// The tab strip's scroll-only decisions: translating a plain wheel onto its
/// horizontal axis, bringing the selected tab into view, and which edges hint
/// at hidden tabs. All three read the same scroll state the strip already
/// reports through `reportsScrollExtent`, never AppKit or SwiftUI types
/// directly, so they stay testable off real geometry.
public enum TabStripScrollGeometry {
    /// The strip's new scroll offset for one wheel event, or `nil` when the
    /// event should pass through untouched. A trackpad swipe already carries
    /// its own horizontal delta, so only a delta with no horizontal
    /// component at all is translated -- otherwise a diagonal swipe would
    /// fight its own X against a translated Y. The sign matches AppKit's own
    /// `scrollingDelta` convention (positive Y is a scroll up), applied to
    /// the horizontal axis the same way a vertical list applies its own
    /// delta: scrolling up moves toward the leading edge.
    public static func wheelOffset(
        current: CGFloat, maximumOffset: CGFloat, deltaX: CGFloat, deltaY: CGFloat
    ) -> CGFloat? {
        guard deltaX == 0, deltaY != 0 else { return nil }
        return min(max(current - deltaY, 0), max(0, maximumOffset))
    }

    /// The offset that brings `frame` (in the strip's scroll content space)
    /// fully into a viewport `viewportWidth` points wide, currently scrolled
    /// to `offset`. `nil` when the frame already fits, so a selection change
    /// that lands on an already-visible tab never moves the strip.
    public static func revealOffset(
        for frame: CGRect, offset: CGFloat, viewportWidth: CGFloat, maximumOffset: CGFloat
    ) -> CGFloat? {
        let visibleMaxX = offset + viewportWidth
        let target: CGFloat
        // Wider than the viewport can ever fit both edges: leading wins, so
        // the tab's own start (its label) is always the part revealed.
        if frame.width > viewportWidth || frame.minX < offset {
            target = frame.minX
        } else if frame.maxX > visibleMaxX {
            target = frame.maxX - viewportWidth
        } else {
            return nil
        }
        return min(max(target, 0), max(0, maximumOffset))
    }

    /// Which edges hint at tabs scrolled out of view. Both `false` whenever
    /// nothing overflows, which is what keeps a strip that fits untouched.
    public struct EdgeFade: Equatable, Sendable {
        public let leading: Bool
        public let trailing: Bool
        public static let none = EdgeFade(leading: false, trailing: false)

        public init(leading: Bool, trailing: Bool) {
            self.leading = leading
            self.trailing = trailing
        }
    }

    public static func edgeFade(offset: CGFloat, maximumOffset: CGFloat) -> EdgeFade {
        guard maximumOffset > 0 else { return .none }
        return EdgeFade(leading: offset > 0, trailing: offset < maximumOffset)
    }
}
