import CoreGraphics

/// Edge auto-scroll for a drag hovering a scrollable strip or rail: inside a
/// band along each scrolling edge, the list scrolls toward that edge at a
/// speed that grows with proximity.
public enum AutoScroll {
    public static let band: CGFloat = 24
    /// Points per second with the pointer on the edge itself.
    public static let maximumSpeed: CGFloat = 900
    /// The longest interval one tick may advance by, so a stalled main
    /// thread resumes scrolling rather than jumping.
    public static let maximumStep: Double = 1.0 / 30

    public enum Axis: Equatable, Sendable {
        case horizontal
        case vertical
    }

    /// Signed points per second along `axis`: negative toward the leading
    /// (left or top) edge, positive toward the trailing one. Zero outside the
    /// viewport and from the band's inner edge inward. The ramp is quadratic
    /// in depth, so the first points into the band barely move the list and
    /// the edge itself runs at `maximumSpeed`. Where the bands of a short
    /// viewport overlap, the nearer edge wins.
    public static func velocity(
        pointer: CGPoint, viewport: CGRect, axis: Axis,
        band: CGFloat = AutoScroll.band, maximumSpeed: CGFloat = AutoScroll.maximumSpeed
    ) -> CGFloat {
        guard band > 0, viewport.contains(pointer) else { return 0 }
        let position = axis == .horizontal ? pointer.x : pointer.y
        let leading = position - (axis == .horizontal ? viewport.minX : viewport.minY)
        let trailing = (axis == .horizontal ? viewport.maxX : viewport.maxY) - position
        let toLeading = leading <= trailing
        let distance = max(0, toLeading ? leading : trailing)
        guard distance < band else { return 0 }
        let proximity = (band - distance) / band
        let speed = maximumSpeed * proximity * proximity
        return toLeading ? -speed : speed
    }
}

/// The tick decision for one drag's auto-scroll, independent of whatever
/// timer drives it.
///
/// Offsets are carried forward from the last step rather than re-read from
/// the scroll view each tick: the view reports its offset back a frame late,
/// and stepping from that stale value would request the same offset twice
/// and stall every other frame.
public struct AutoScroller: Equatable, Sendable {
    public enum Surface: Hashable, Sendable {
        case strip
        case rail
        case grid
    }

    public struct Region: Equatable, Sendable {
        public let surface: Surface
        /// The scroll view's own on-screen frame, in the drag space.
        public let viewport: CGRect
        public let axis: AutoScroll.Axis
        public let offset: CGFloat
        /// Zero when the content fits, which is what makes a list that is
        /// not overflowing never scroll.
        public let maximumOffset: CGFloat

        public init(surface: Surface, viewport: CGRect, axis: AutoScroll.Axis, offset: CGFloat, maximumOffset: CGFloat) {
            self.surface = surface
            self.viewport = viewport
            self.axis = axis
            self.offset = offset
            self.maximumOffset = maximumOffset
        }
    }

    public struct Step: Equatable, Sendable {
        public let surface: Surface
        public let offset: CGFloat

        public init(surface: Surface, offset: CGFloat) {
            self.surface = surface
            self.offset = offset
        }
    }

    private var carried: Step?
    /// A band a spring load fired in. It stays still until the pointer has
    /// left it: the reveal just changed what is under the pointer, and
    /// scrolling on would carry the drop somewhere the user never looked.
    private var suppressed: Surface?

    public init() {}

    /// Call on every pointer move. Forgets whatever the pointer has left and
    /// reports whether a ticker should be running for where it is now.
    public mutating func pointerMoved(to pointer: CGPoint, regions: [Region]) -> Bool {
        guard let hovered = Self.hovered(pointer, regions) else {
            carried = nil
            suppressed = nil
            return false
        }
        if let suppressed, suppressed != hovered.region.surface {
            self.suppressed = nil
        }
        if let carried, carried.surface != hovered.region.surface {
            self.carried = nil
        }
        guard suppressed != hovered.region.surface else { return false }
        let offset = currentOffset(hovered.region)
        return hovered.velocity < 0 ? offset > 0 : offset < hovered.region.maximumOffset
    }

    /// One frame of scrolling: where the hovered surface should scroll to,
    /// or nil to hold still.
    public mutating func tick(pointer: CGPoint, regions: [Region], elapsed: Double) -> Step? {
        guard let hovered = Self.hovered(pointer, regions) else {
            carried = nil
            suppressed = nil
            return nil
        }
        if let suppressed {
            guard suppressed != hovered.region.surface else { return nil }
            self.suppressed = nil
        }
        let base = currentOffset(hovered.region)
        let interval = CGFloat(min(max(elapsed, 0), AutoScroll.maximumStep))
        let next = min(max(base + hovered.velocity * interval, 0), max(hovered.region.maximumOffset, 0))
        let step = Step(surface: hovered.region.surface, offset: next)
        carried = step
        return next == base ? nil : step
    }

    public mutating func springLoaded(pointer: CGPoint, regions: [Region]) {
        carried = nil
        suppressed = Self.hovered(pointer, regions)?.region.surface
    }

    public mutating func reset() {
        carried = nil
        suppressed = nil
    }

    private func currentOffset(_ region: Region) -> CGFloat {
        guard let carried, carried.surface == region.surface else { return region.offset }
        return carried.offset
    }

    private static func hovered(_ pointer: CGPoint, _ regions: [Region]) -> (region: Region, velocity: CGFloat)? {
        for region in regions {
            let velocity = AutoScroll.velocity(pointer: pointer, viewport: region.viewport, axis: region.axis)
            if velocity != 0 {
                return (region, velocity)
            }
        }
        return nil
    }
}
