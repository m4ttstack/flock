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
    /// handle strip is taken off the top. Every caller that turns a
    /// thumbnail's reported frame into mini-pane boxes goes through this, so
    /// the strip cannot shift a box under the pointer that is aimed at it.
    public static func paneArea(in thumbnail: CGRect, stripHeight: CGFloat) -> CGRect {
        CGRect(
            x: thumbnail.minX, y: thumbnail.minY + stripHeight,
            width: thumbnail.width, height: max(0, thumbnail.height - stripHeight)
        )
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
