import CoreGraphics

/// Where a vertical divider's hit band crosses a horizontal one's (a T or a
/// plus): both bands cover the same square there, so a press inside it needs
/// a single deterministic owner -- see `DividerIntersections.resolve`.
public struct DividerIntersection: Equatable, Sendable {
    public let vertical: DividerHandle
    public let horizontal: DividerHandle
    public let square: CGRect

    /// Stable across a live drag, unlike `square` (which moves with either
    /// divider's own ratio): the pair of split paths that produced this
    /// crossing.
    public var id: String { "\(vertical.path)x\(horizontal.path)" }
}

public enum DividerIntersections {
    /// Every overlap between a vertical divider's band and a horizontal
    /// one's, both widened to `bandThickness`. The `tabID` check is
    /// defensive: `dividers` is always one tab's geometry today, but two
    /// mismatched tabs must never be paired into a crossing that does not
    /// exist on screen.
    public static func find(in dividers: [DividerHandle], bandThickness: CGFloat) -> [DividerIntersection] {
        let verticals = dividers.filter(\.isVerticalLine)
        let horizontals = dividers.filter { !$0.isVerticalLine }
        guard !verticals.isEmpty, !horizontals.isEmpty else { return [] }

        var out: [DividerIntersection] = []
        for vertical in verticals {
            let vBand = vertical.hitBand(thickness: bandThickness)
            for horizontal in horizontals {
                guard horizontal.tabID == vertical.tabID else { continue }
                let square = vBand.intersection(horizontal.hitBand(thickness: bandThickness))
                guard square.width > 0, square.height > 0 else { continue }
                out.append(DividerIntersection(vertical: vertical, horizontal: horizontal, square: square))
            }
        }
        return out
    }

    /// Which divider a press at `point` (same space as `square`) belongs
    /// to: whichever centerline is nearer. A tie resolves to the vertical
    /// divider -- arbitrary, but fixed, so a press can never be read as
    /// belonging to both.
    public static func resolve(_ intersection: DividerIntersection, at point: CGPoint) -> DividerHandle {
        let toVertical = abs(point.x - intersection.vertical.frame.midX)
        let toHorizontal = abs(point.y - intersection.horizontal.frame.midY)
        return toVertical <= toHorizontal ? intersection.vertical : intersection.horizontal
    }
}
