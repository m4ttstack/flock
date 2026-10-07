import CoreGraphics

/// How a lane's two subgroups share the height below its heading. Both fit:
/// each at its own height. Otherwise each is capped at half: one under its
/// half keeps its height and the other takes the rest, scrolling; both over
/// get half each. One subgroup alone takes all of it.
public enum LaneSplit {
    public struct Allocation: Equatable, Sendable {
        public let top: CGFloat
        public let bottom: CGFloat
        public let topScrolls: Bool
        public let bottomScrolls: Bool

        public init(top: CGFloat, bottom: CGFloat, topScrolls: Bool, bottomScrolls: Bool) {
            self.top = top
            self.bottom = bottom
            self.topScrolls = topScrolls
            self.bottomScrolls = bottomScrolls
        }
    }

    /// Sub-point differences are layout rounding, not content to scroll to.
    static let tolerance: CGFloat = 0.5

    /// `top` and `bottom` are each subgroup's ideal height, label included,
    /// and 0 for an empty one; they must be measured unconstrained, never from
    /// a frame this handed out, or the split feeds back into itself. `height`
    /// is what the two share, the gap between them already taken out. A floor
    /// is a subgroup's label and first card: each keeps at least that, and
    /// when the two floors cannot both fit, the top one does.
    public static func allocate(
        top: CGFloat, bottom: CGFloat, height: CGFloat, topFloor: CGFloat, bottomFloor: CGFloat
    ) -> Allocation {
        let height = max(0, height)
        let top = max(0, top), bottom = max(0, bottom)
        func allocation(_ t: CGFloat, _ b: CGFloat) -> Allocation {
            Allocation(top: t, bottom: b, topScrolls: top > t + tolerance, bottomScrolls: bottom > b + tolerance)
        }
        guard top > 0, bottom > 0 else { return allocation(min(top, height), min(bottom, height)) }
        guard top + bottom > height + tolerance else { return allocation(top, bottom) }

        let half = height / 2
        var t: CGFloat, b: CGFloat
        if top <= half {
            (t, b) = (top, height - top)
        } else if bottom <= half {
            (t, b) = (height - bottom, bottom)
        } else {
            (t, b) = (half, half)
        }
        let topFloor = min(max(0, topFloor), top), bottomFloor = min(max(0, bottomFloor), bottom)
        if topFloor + bottomFloor > height {
            t = min(topFloor, height)
            b = height - t
        } else if t < topFloor {
            (t, b) = (topFloor, height - topFloor)
        } else if b < bottomFloor {
            (t, b) = (height - bottomFloor, bottomFloor)
        }
        return allocation(t, b)
    }
}
