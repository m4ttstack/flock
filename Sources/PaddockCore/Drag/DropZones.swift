import CoreGraphics

/// The two "create something new" drop zones, derived from the free run a
/// strip or rail already has rather than from a button: the tab strip's space
/// after the last tab and before its trailing readout, and the workspace
/// rail's space below the last row.
///
/// A run shorter than `minimumExtent` yields no zone at all, so a full strip
/// or rail cannot grow an accidental target a pixel wide.
public enum DropZones {
    public static let minimumExtent: CGFloat = 56
    /// Breathing room between a zone and whatever it borders. A zone drawn
    /// flush against the last item, the window edge and the chrome above it
    /// reads as a rendering artifact rather than as a target.
    public static let margin: CGFloat = 10

    public static func trailing(
        in container: CGRect,
        itemsEndingAt itemsEnd: CGFloat?,
        before limit: CGFloat,
        minimumExtent: CGFloat = DropZones.minimumExtent
    ) -> CGRect? {
        let start = max(itemsEnd ?? container.minX, container.minX) + margin
        let end = min(limit, container.maxX) - margin
        guard end - start >= minimumExtent else { return nil }
        return CGRect(
            x: start, y: container.minY + margin / 2,
            width: end - start, height: max(0, container.height - margin)
        )
    }

    public static func below(
        in container: CGRect,
        itemsEndingAt itemsEnd: CGFloat?,
        minimumExtent: CGFloat = DropZones.minimumExtent
    ) -> CGRect? {
        let start = max(itemsEnd ?? container.minY, container.minY) + margin
        let end = container.maxY - margin
        guard end - start >= minimumExtent else { return nil }
        return CGRect(
            x: container.minX + margin / 2, y: start,
            width: max(0, container.width - margin), height: end - start
        )
    }
}
