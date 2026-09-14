import CoreGraphics

/// The pinned drag treatments, in one place so no view spells a number
/// inline. Durations are seconds, matching SwiftUI's own animation
/// parameters.
public enum DragVisuals {
    /// What the origin item fades to while its ghost is out.
    public static let originOpacity: CGFloat = 0.4
    /// The ghost's top-left corner relative to the cursor.
    public static let ghostCursorOffset = CGSize(width: 16, height: 8)
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

    /// The ghost's top-left for a cursor at `point`, both in the same space.
    public static func ghostTopLeft(forCursor point: CGPoint) -> CGPoint {
        CGPoint(x: point.x + ghostCursorOffset.width, y: point.y + ghostCursorOffset.height)
    }

    /// The proxy's size: the origin item scaled down but never past
    /// `maximum`, aspect preserved, so a full-window pane and a tab pill both
    /// produce something small enough to see the drop target under.
    public static func ghostSize(forOrigin origin: CGSize, maximum: CGSize = CGSize(width: 260, height: 160)) -> CGSize {
        guard origin.width > 0, origin.height > 0 else { return maximum }
        let scale = min(1, min(maximum.width / origin.width, maximum.height / origin.height))
        return CGSize(width: origin.width * scale, height: origin.height * scale)
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

/// Which presses on a pane body arm a drag: any of them while rearrange mode
/// is active, otherwise only the band along the body's top edge (the legend
/// is its own view and carries its own gesture).
///
/// `point` and `bounds` are in the body's own space with a TOP-LEFT origin;
/// an AppKit caller flips before calling, never after.
public enum PaneGrabRegion {
    public static let topBandHeight: CGFloat = 12

    public static func armsDrag(at point: CGPoint, in bounds: CGRect, rearrangeActive: Bool) -> Bool {
        guard bounds.contains(point) else { return false }
        if rearrangeActive { return true }
        return point.y - bounds.minY <= topBandHeight
    }
}

/// How far a strip/rail item slides while a reorder drag is in flight: the
/// dragged item leaves a hole behind it and the insertion point opens one
/// ahead of it, so the two cancel outside the moved range and only the items
/// actually between the old and new position move at all.
public enum ReshuffleOffset {
    /// What a cross-list drag (a tab from another workspace) opens, having no
    /// item of its own in this list to take the extent from.
    public static let defaultExtent: CGFloat = 56

    public static func displacement(forItemAt index: Int, draggingIndex: Int?, insertIndex: Int, extent: CGFloat) -> CGFloat {
        guard index != draggingIndex else { return 0 }
        var displacement: CGFloat = 0
        if let draggingIndex, index > draggingIndex { displacement -= extent }
        if index >= insertIndex { displacement += extent }
        return displacement
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
