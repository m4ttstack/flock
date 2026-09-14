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

/// Where a pane can be grabbed.
///
/// At rest the handle is the cell's top chrome: the legend line plus the inset
/// above the terminal surface. That band is chrome the cell already spends, so
/// it costs no terminal rows and the terminal's first line stays selectable
/// text. The body itself is the terminal's until rearrange mode is active, at
/// which point the whole pane is a drag surface.
public enum PaneGrabRegion {
    /// From the cell's own top edge down to the first terminal row: half the
    /// legend's height (the part above the box) plus the box's top inset.
    /// Derived from the cell's real metrics rather than fixed, so the band and
    /// the surface cannot drift apart.
    public static func topChromeHeight(legendHalfHeight: CGFloat, contentInsetTop: CGFloat) -> CGFloat {
        legendHalfHeight + contentInsetTop
    }

    /// Whether a press in the pane BODY arms a drag. `point` and `bounds` are
    /// in the body's own space with a TOP-LEFT origin; an AppKit caller flips
    /// before calling, never after.
    public static func bodyArmsDrag(at point: CGPoint, in bounds: CGRect, rearrangeActive: Bool) -> Bool {
        rearrangeActive && bounds.contains(point)
    }
}

/// How far a strip/rail item slides while a reorder drag is in flight: the
/// standard reorder shift, previewing the WHOLE post-drop arrangement.
///
/// Each item between the origin and the insertion point moves one slot toward
/// the origin, and the origin takes the one slot they vacate. Items outside
/// that range do not move. The origin moving is what keeps the preview an
/// arrangement rather than an overlap: it stays in the list at
/// `DragVisuals.originOpacity`, so an origin pinned to its old slot would have
/// the neighbour that slides into that slot drawn straight on top of it.
public enum ReshuffleOffset {
    /// What a cross-list drag (a tab from another workspace) opens, having no
    /// item of its own in this list to take the extent from.
    public static let defaultExtent: CGFloat = 56

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
