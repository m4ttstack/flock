import CoreGraphics

/// A tab's split layout drawn small, for the All Workspaces grid. It is the
/// canvas's own geometry pass run over a thumbnail, fed by the layout snapshot
/// and the cached export alone: nothing here reaches a live surface, so a
/// thumbnail never resizes the pane it stands for.
public enum MiniPaneLayout {
    public struct Placed: Equatable, Sendable {
        public let pane: PaneID
        public let frame: CGRect
    }

    /// What is left of a thumbnail for its mini panes, once the tab's own
    /// handle strip is taken off the top. This is where the strip's own
    /// geometry is stated; `boxInThumbnail` reads the offset back out of it,
    /// so a strip that grows a hairline or an inset moves both together.
    public static func paneArea(in thumbnail: CGRect, stripHeight: CGFloat) -> CGRect {
        CGRect(
            x: thumbnail.minX, y: thumbnail.minY + stripHeight,
            width: thumbnail.width, height: max(0, thumbnail.height - stripHeight)
        )
    }

    /// A mini pane's box, stated in the pane AREA's space, moved into the
    /// thumbnail's. A drag records its spring-back home against the
    /// thumbnail, since that is the grid item whose live frame the home is
    /// read back from, so the two spaces have to meet somewhere and this is
    /// the only place they do.
    public static func boxInThumbnail(_ box: CGRect, stripHeight: CGFloat) -> CGRect {
        let area = paneArea(in: .zero, stripHeight: stripHeight)
        return box.offsetBy(dx: area.minX, dy: area.minY)
    }

    /// Every pane's box inside a thumbnail of `size`, top to bottom and then
    /// left to right as drawn. Outer boxes sit exactly `padding` inside the
    /// thumbnail and neighbors `gap` apart. A tab with no layout yet stacks
    /// `fallbackPanes` evenly rather than drawing nothing.
    public static func boxes(
        layout: LayoutSnapshot?,
        exported: ExportedLayoutDescription?,
        fallbackPanes: [PaneID],
        size: CGSize,
        padding: CGFloat,
        gap: CGFloat,
        displayScale: CGFloat
    ) -> [Placed] {
        let insets = PaneBox.canvasPadding(margin: padding, dividerThickness: gap)
        let area = CGSize(
            width: max(0, size.width - insets.leadingAndTop - insets.trailingAndBottom),
            height: max(0, size.height - insets.leadingAndTop - insets.trailingAndBottom)
        )
        let grid = CanvasGrid(canvas: area, displayScale: displayScale)
        let frames: [PaneID: CGRect]
        if let layout, !layout.panes.isEmpty {
            frames = CanvasGeometry.resolved(layout: layout, exported: exported, grid: grid, dividerThickness: gap).paneFrames
        } else {
            let stack = CellRect(x: 0, y: 0, width: 1, height: max(fallbackPanes.count, 1))
            frames = Dictionary(
                fallbackPanes.enumerated().map { ($0.element, grid.frame(for: CellRect(x: 0, y: $0.offset, width: 1, height: 1), area: stack)) },
                uniquingKeysWith: { first, _ in first }
            )
        }
        return frames
            .map { Placed(pane: $0.key, frame: PaneBox.frame(in: $0.value, dividerThickness: gap).offsetBy(dx: insets.leadingAndTop, dy: insets.leadingAndTop)) }
            .sorted { ($0.frame.minY, $0.frame.minX, $0.pane.rawValue) < ($1.frame.minY, $1.frame.minX, $1.pane.rawValue) }
    }
}
