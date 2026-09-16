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

    /// A pane a drop would land in this tab, for the preview. herdr splits
    /// the tab's focused pane when a `pane.move` names the tab and no pane of
    /// it, and a `movePaneToTab` split always keeps the target as the first
    /// child, so the arriving pane takes the right half of whatever the
    /// focused pane occupies.
    public struct Arrival: Equatable, Sendable {
        public let pane: PaneID
        public let besideFocused: PaneID

        public init(pane: PaneID, besideFocused: PaneID) {
            self.pane = pane
            self.besideFocused = besideFocused
        }

        /// The split the drop produces, stated as the canvas's own drop
        /// target so the preview and a canvas edge drop are the same
        /// transform.
        var target: DropTarget { .paneEdge(besideFocused, .right) }
    }

    /// What a live drag would land in `tab`, or nil when nothing does: no
    /// drag, a drag aimed elsewhere, a subject that is not a pane, or a pane
    /// already in this tab, which herdr refuses outright (`same_tab`). Keyed
    /// on the planned outcome rather than on the resolved target, so a drop
    /// that commits nothing previews nothing.
    public static func arrival(of subject: DragSubject?, onto target: DropTarget?, tab: TabID, model: SessionModel?) -> Arrival? {
        guard let target, case .tabThumbnail(let hit) = target, hit == tab,
              let subject, case .pane(let pane) = subject,
              let model, case .success = plan(dragging: subject, onto: target, model: model),
              let focused = model.layouts[tab]?.focusedPane
        else {
            return nil
        }
        return Arrival(pane: pane, besideFocused: focused)
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
    ///
    /// With an `arriving` pane the boxes are the ones the drop leaves behind,
    /// the arriving pane's included: the same geometry pass over the same
    /// tree transform a canvas edge drop previews with, so what a thumbnail
    /// opens and what herdr then builds cannot drift.
    public static func boxes(
        layout: LayoutSnapshot?,
        exported: ExportedLayoutDescription?,
        fallbackPanes: [PaneID],
        size: CGSize,
        padding: CGFloat,
        gap: CGFloat,
        displayScale: CGFloat,
        arriving: Arrival? = nil
    ) -> [Placed] {
        let insets = PaneBox.canvasPadding(margin: padding, dividerThickness: gap)
        let area = CGSize(
            width: max(0, size.width - insets.leadingAndTop - insets.trailingAndBottom),
            height: max(0, size.height - insets.leadingAndTop - insets.trailingAndBottom)
        )
        let grid = CanvasGrid(canvas: area, displayScale: displayScale)
        let frames: [PaneID: CGRect]
        if let layout, !layout.panes.isEmpty, let arriving {
            frames = landing(arriving, in: layout, exported: exported, grid: grid, gap: gap)
        } else if let layout, !layout.panes.isEmpty {
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

    /// The tab's panes as the drop leaves them. herdr's own split tree is the
    /// exact answer wherever one is cached: the arriving pane is grafted on
    /// by `DropPreview`, which is the transform the canvas previews an edge
    /// drop with, and the same geometry pass lays the result out.
    ///
    /// Without a tree the snapshot's own rects carry it: a `pane.move` only
    /// ever divides the one region it is aimed at, so splitting the focused
    /// pane's cell rect leaves every other pane exactly where it was.
    private static func landing(
        _ arriving: Arrival, in layout: LayoutSnapshot, exported: ExportedLayoutDescription?, grid: CanvasGrid, gap: CGFloat
    ) -> [PaneID: CGRect] {
        if let exported, exported.tabID == layout.tabID,
           let root = DropPreview.root(exported.root, dropping: arriving.pane, onto: arriving.target) {
            return CanvasGeometry(
                exportedRoot: root, area: layout.area, tabID: layout.tabID, grid: grid, dividerThickness: gap
            ).paneFrames
        }
        guard let focused = layout.panes.first(where: { $0.paneID == arriving.besideFocused }) else {
            return CanvasGeometry.resolved(layout: layout, exported: exported, grid: grid, dividerThickness: gap).paneFrames
        }
        let regions = SplitTree.childRegions(of: focused.rect, direction: .right, ratio: 0.5)
        var preview = layout
        preview.panes = layout.panes.filter { $0.paneID != arriving.pane && $0.paneID != focused.paneID }
            + [
                PaneRect(paneID: focused.paneID, focused: focused.focused, rect: regions.first),
                PaneRect(paneID: arriving.pane, focused: false, rect: regions.second),
            ]
        return CanvasGeometry.resolved(layout: preview, exported: nil, grid: grid, dividerThickness: gap).paneFrames
    }
}
