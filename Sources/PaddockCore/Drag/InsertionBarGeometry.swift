import CoreGraphics

/// Where the reorder insertion bar is drawn: a thin accent line in the gap an
/// insert index names, with a dot on its leading end.
///
/// Every frame here is in whatever space the caller's item frames are in; the
/// bar is derived from those frames alone, never from a layout pass.
public enum InsertionBarGeometry {
    public enum Axis: Sendable {
        /// A vertical bar in a horizontally laid out strip.
        case vertical
        /// A horizontal bar in a vertically laid out rail.
        case horizontal
    }

    public static let thickness: CGFloat = 2
    public static let dotDiameter: CGFloat = 8
    /// How far the bar overhangs the items' own cross-axis extent.
    public static let crossOutset: CGFloat = 3
    /// The gap assumed either side of a lone item, and inside an empty
    /// container: real gaps are measured from the items themselves.
    public static let assumedGap: CGFloat = 8

    public static func bar(atInsertIndex index: Int, items: [CGRect], container: CGRect, axis: Axis) -> CGRect {
        let center = mainCenter(atInsertIndex: index, items: items, container: container, axis: axis)
        let (crossMin, crossMax) = crossExtent(items: items, container: container, axis: axis)
        switch axis {
        case .vertical:
            return CGRect(x: center - thickness / 2, y: crossMin, width: thickness, height: crossMax - crossMin)
        case .horizontal:
            return CGRect(x: crossMin, y: center - thickness / 2, width: crossMax - crossMin, height: thickness)
        }
    }

    /// The dot sits centered on the bar's leading end: the top of a vertical
    /// bar, the left of a horizontal one.
    public static func endDot(for bar: CGRect, axis: Axis) -> CGRect {
        let size = CGSize(width: dotDiameter, height: dotDiameter)
        switch axis {
        case .vertical:
            return CGRect(origin: CGPoint(x: bar.midX - dotDiameter / 2, y: bar.minY - dotDiameter / 2), size: size)
        case .horizontal:
            return CGRect(origin: CGPoint(x: bar.minX - dotDiameter / 2, y: bar.midY - dotDiameter / 2), size: size)
        }
    }

    private static func mainCenter(atInsertIndex index: Int, items: [CGRect], container: CGRect, axis: Axis) -> CGFloat {
        let leading = items.map { axis == .vertical ? $0.minX : $0.minY }
        let trailing = items.map { axis == .vertical ? $0.maxX : $0.maxY }
        let containerLeading = axis == .vertical ? container.minX : container.minY
        let containerTrailing = axis == .vertical ? container.maxX : container.maxY

        guard !leading.isEmpty else {
            return containerLeading + assumedGap
        }

        let gaps = (1..<max(1, leading.count)).map { leading[$0] - trailing[$0 - 1] }
        let halfGap = (gaps.min() ?? assumedGap) / 2
        let clamped = min(max(index, 0), leading.count)
        let center: CGFloat
        if clamped == 0 {
            center = leading[0] - halfGap
        } else if clamped == leading.count {
            center = trailing[clamped - 1] + halfGap
        } else {
            center = (trailing[clamped - 1] + leading[clamped]) / 2
        }
        // Kept inside the container by its own half-thickness, so a bar in
        // the first or last gap is never half-clipped by the chrome edge.
        return min(max(center, containerLeading + thickness / 2), containerTrailing - thickness / 2)
    }

    private static func crossExtent(items: [CGRect], container: CGRect, axis: Axis) -> (CGFloat, CGFloat) {
        let mins = items.map { axis == .vertical ? $0.minY : $0.minX }
        let maxes = items.map { axis == .vertical ? $0.maxY : $0.maxX }
        guard let low = mins.min(), let high = maxes.max() else {
            let containerLow = axis == .vertical ? container.minY : container.minX
            let containerHigh = axis == .vertical ? container.maxY : container.maxX
            return (containerLow + assumedGap, containerHigh - assumedGap)
        }
        return (low - crossOutset, high + crossOutset)
    }
}
