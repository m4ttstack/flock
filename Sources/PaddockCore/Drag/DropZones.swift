import CoreGraphics

/// The two "create something new" drop zones, derived from the free run a
/// strip or rail already has rather than from a button: the tab strip's space
/// after the last pill and before its trailing readout, and the workspace
/// rail's space below the last row.
///
/// A run shorter than `minimumExtent` yields no zone at all, so a full strip
/// or rail cannot grow an accidental target a pixel wide.
public enum DropZones {
    public static let minimumExtent: CGFloat = 44

    public static func trailing(
        in container: CGRect,
        itemsEndingAt itemsEnd: CGFloat?,
        before limit: CGFloat,
        minimumExtent: CGFloat = DropZones.minimumExtent
    ) -> CGRect? {
        let start = max(itemsEnd ?? container.minX, container.minX)
        let end = min(limit, container.maxX)
        guard end - start >= minimumExtent else { return nil }
        return CGRect(x: start, y: container.minY, width: end - start, height: container.height)
    }

    public static func below(
        in container: CGRect,
        itemsEndingAt itemsEnd: CGFloat?,
        minimumExtent: CGFloat = DropZones.minimumExtent
    ) -> CGRect? {
        let start = max(itemsEnd ?? container.minY, container.minY)
        guard container.maxY - start >= minimumExtent else { return nil }
        return CGRect(x: container.minX, y: start, width: container.width, height: container.maxY - start)
    }
}
