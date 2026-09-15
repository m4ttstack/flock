import CoreGraphics

/// The pinned drag treatments, in one place so no view spells a number
/// inline. Durations are seconds, matching SwiftUI's own animation
/// parameters.
public enum DragVisuals {
    /// What the origin item fades to while its ghost is out.
    public static let originOpacity: CGFloat = 0.4
    /// The ghost's top-left corner relative to the cursor.
    /// Strip/rail reshuffle, run when the insertion index changes -- which is
    /// exactly when the dragged item's center crosses a neighbor's, since
    /// that is the rule `resolveDropTarget` derives the index by.
    public static let reshuffleDuration: Double = 0.1
    /// Drop-settle and cancel spring-back share one curve, so a drop that
    /// bounces home travels the same way it would have landed.
    public static let settleDuration: Double = 0.35
    public static let settleBounce: Double = 0.15
    /// How long the landing zone flashes after a committed drop.
    public static let landingFlashDuration: Double = 0.7
    /// The dropzone preview's cross-fade as the target changes.
    public static let previewCrossfadeDuration: Double = 0.12
    /// The strip's scroll when the selected tab changes off screen.
    public static let tabRevealDuration: Double = 0.2
    /// The accent laid over whatever a pane drop is aimed at: the canvas
    /// preview and a targeted grid thumbnail.
    public static let dropWashOpacity: Double = 0.22

    /// The ghost's top-left for a cursor at `point`, both in the same space:
    /// the proxy is centered on the pointer, so what the pointer is over is
    /// what the drop resolves against.
    public static func ghostTopLeft(forCursor point: CGPoint, ghostSize: CGSize) -> CGPoint {
        CGPoint(x: point.x - ghostSize.width / 2, y: point.y - ghostSize.height / 2)
    }

    /// What a proxy may not outgrow, and what it may not shrink below.
    /// `maximum` is the hard bound of the two (see `ghostSize`).
    public struct GhostBounds: Equatable, Sendable {
        public let maximum: CGSize
        public let minimum: CGSize

        public init(maximum: CGSize, minimum: CGSize) {
            self.maximum = maximum
            self.minimum = minimum
        }
    }

    /// A drag in the window: a full-window pane has to come down far enough to
    /// see the target under it, and a tab pill has to come up far enough to
    /// read.
    public static let ghostBounds = GhostBounds(
        maximum: CGSize(width: 333, height: 205), minimum: CGSize(width: 192, height: 41)
    )

    /// A drag that starts inside the All Workspaces grid, where a thumbnail is
    /// around 103x82 and a mini pane smaller still: at window bounds the proxy
    /// would cover the target it is aimed at and most of its card.
    public static let compactGhostBounds = GhostBounds(
        maximum: CGSize(width: 112, height: 88), minimum: CGSize(width: 44, height: 22)
    )

    /// The proxy's size: the origin at ONE scale factor, so the proxy is
    /// always the dragged item's own shape. Never a per-axis stretch, which
    /// hands a tall pane the same box as a wide one.
    ///
    /// The factor is 1 -- the item's own footprint -- unless that overflows
    /// `bounds.maximum`, where it shrinks to fit, or falls under
    /// `bounds.minimum`, where it grows to reach it. The maximum is the hard
    /// bound: an origin whose shape cannot satisfy both (far wider or far
    /// narrower than either box) stays inside the maximum and comes out under
    /// the minimum, since a proxy that covers the drop target is worse than a
    /// small one.
    public static func ghostSize(forOrigin origin: CGSize, bounds: GhostBounds = DragVisuals.ghostBounds) -> CGSize {
        guard origin.width > 0, origin.height > 0 else { return bounds.minimum }
        let fit = min(bounds.maximum.width / origin.width, bounds.maximum.height / origin.height)
        let lift = max(bounds.minimum.width / origin.width, bounds.minimum.height / origin.height)
        let scale = min(fit, max(1, lift))
        return CGSize(width: origin.width * scale, height: origin.height * scale)
    }

    /// Where the proxy settles when a drop does not commit: centered on the
    /// item it was picked up from, so it bounces back onto that item rather
    /// than onto wherever inside it the press happened to land. `origin` is
    /// that item's frame in the drag space; without one the press point is the
    /// best available stand-in.
    public static func settleHomeTopLeft(origin: CGRect?, grabPoint: CGPoint, ghostSize: CGSize) -> CGPoint {
        let home = origin.map { CGPoint(x: $0.midX, y: $0.midY) } ?? grabPoint
        return ghostTopLeft(forCursor: home, ghostSize: ghostSize)
    }
}

/// How far the pointer must travel from the press point before that press
/// becomes a drag. Below it the press is still a plain click.
public enum DragThreshold {
    public static let movement: CGFloat = 4

    public static func passed(from origin: CGPoint, to point: CGPoint) -> Bool {
        let dx = point.x - origin.x
        let dy = point.y - origin.y
        return (dx * dx + dy * dy) >= movement * movement
    }
}

/// Where a pane can be grabbed.
///
/// At rest the handle is the box's top chrome (`PaneChrome.contentTop`): the
/// padding and title row above the terminal surface. That band is chrome the
/// box already spends, so it costs no terminal rows and the terminal's first
/// line stays selectable text. The body itself is the terminal's until
/// rearrange mode is active, at which point the whole pane is a drag surface.
public enum PaneGrabRegion {
    /// Whether a press in the pane BODY arms a drag. `point` and `bounds` are
    /// in the body's own space with a TOP-LEFT origin; an AppKit caller flips
    /// before calling, never after.
    public static func bodyArmsDrag(at point: CGPoint, in bounds: CGRect, rearrangeActive: Bool) -> Bool {
        rearrangeActive && bounds.contains(point)
    }
}

/// How far a strip/rail item slides while a reorder drag is in flight.
///
/// The invariant: a reorder previews the COMPLETE post-drop arrangement,
/// origin included, so exactly one item occupies each slot and nothing is ever
/// drawn on top of anything else. Each item between the origin and the
/// insertion point moves one slot toward the origin; the origin takes the one
/// slot they vacate; items outside that range do not move. The origin has to
/// move like the rest because it is still IN the list, drawn at
/// `DragVisuals.originOpacity` rather than lifted out of it.
public enum ReshuffleOffset {
    /// What a cross-list drag (a tab from another workspace) opens, having no
    /// item of its own in this list to take the extent from.
    public static let defaultExtent: CGFloat = 72

    public static func displacement(forItemAt index: Int, draggingIndex: Int?, insertIndex: Int, extent: CGFloat) -> CGFloat {
        // Nothing of this list is moving, so the gap is simply opened at the
        // insertion point for the arriving item.
        guard let draggingIndex else {
            return index >= insertIndex ? extent : 0
        }
        // `insertIndex` counts gaps, so a gap past the origin names a
        // destination one slot lower once the origin itself has moved out of
        // the way.
        let destination = insertIndex > draggingIndex ? insertIndex - 1 : insertIndex
        if index == draggingIndex {
            return CGFloat(destination - draggingIndex) * extent
        }
        if index > draggingIndex, index <= destination {
            return -extent
        }
        if index < draggingIndex, index >= destination {
            return extent
        }
        return 0
    }

    /// The same invariant for a block: its members leave their slots, land
    /// together in list order at the gap, and every item takes the slot that
    /// post-drop order gives it. Slots are rebuilt from each item's own
    /// advance rather than from one shared extent, because a block's members
    /// need not be neighbors.
    public static func blockDisplacement(
        forItemAt index: Int, blockIndices: Set<Int>, insertIndex: Int, items: [CGRect], axis: InsertionBarGeometry.Axis
    ) -> CGFloat {
        guard items.indices.contains(index), let first = items.first else { return 0 }
        func leading(_ rect: CGRect) -> CGFloat { axis == .vertical ? rect.minX : rect.minY }
        let unmoved = items.indices.filter { !blockIndices.contains($0) }
        let landed = unmoved.filter { $0 < insertIndex }
            + items.indices.filter(blockIndices.contains)
            + unmoved.filter { $0 >= insertIndex }
        guard let slot = landed.firstIndex(of: index) else { return 0 }
        let position = landed[..<slot].reduce(leading(first)) { $0 + advance(ofItemAt: $1, items: items, axis: axis) }
        return position - leading(items[index])
    }

    /// The main-axis distance an item occupies including the gap to its
    /// neighbor: how far the list shifts when that item leaves or arrives.
    /// Measured from the frames themselves, so no view's spacing constant has
    /// to be mirrored here to stay correct.
    public static func advance(ofItemAt index: Int, items: [CGRect], axis: InsertionBarGeometry.Axis) -> CGFloat {
        guard items.indices.contains(index) else { return defaultExtent }
        func leading(_ rect: CGRect) -> CGFloat { axis == .vertical ? rect.minX : rect.minY }
        func trailing(_ rect: CGRect) -> CGFloat { axis == .vertical ? rect.maxX : rect.maxY }
        if items.indices.contains(index + 1) {
            return leading(items[index + 1]) - leading(items[index])
        }
        if items.indices.contains(index - 1) {
            return trailing(items[index]) - trailing(items[index - 1])
        }
        return trailing(items[index]) - leading(items[index])
    }
}
