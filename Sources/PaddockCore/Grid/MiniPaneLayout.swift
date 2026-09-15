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

    /// Every pane's box inside a thumbnail of `size`, in reading order. Outer
    /// boxes sit exactly `padding` inside the thumbnail and neighbors `gap`
    /// apart. A tab with no layout yet stacks `fallbackPanes` evenly rather
    /// than drawing nothing.
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
        let order: [PaneID]
        if let layout, !layout.panes.isEmpty {
            frames = CanvasGeometry.resolved(layout: layout, exported: exported, grid: grid, dividerThickness: gap).paneFrames
            order = readingOrder(layout: layout, fallbackPanes: [])
        } else {
            let stack = CellRect(x: 0, y: 0, width: 1, height: max(fallbackPanes.count, 1))
            frames = Dictionary(
                fallbackPanes.enumerated().map { ($0.element, grid.frame(for: CellRect(x: 0, y: $0.offset, width: 1, height: 1), area: stack)) },
                uniquingKeysWith: { first, _ in first }
            )
            order = fallbackPanes
        }
        return order.compactMap { pane in
            frames[pane].map {
                Placed(pane: pane, frame: PaneBox.frame(in: $0, dividerThickness: gap).offsetBy(dx: insets.leadingAndTop, dy: insets.leadingAndTop))
            }
        }
    }

    /// Top to bottom, then left to right, by cell position.
    public static func readingOrder(layout: LayoutSnapshot?, fallbackPanes: [PaneID]) -> [PaneID] {
        guard let layout, !layout.panes.isEmpty else { return fallbackPanes }
        return layout.panes
            .sorted { ($0.rect.y, $0.rect.x) < ($1.rect.y, $1.rect.x) }
            .map(\.paneID)
    }
}
