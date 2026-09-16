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

    /// A pane a drop would land in this tab, for the preview.
    public struct Arrival: Equatable, Sendable {
        public let pane: PaneID
        /// The split the drop produces, stated as the canvas's own drop
        /// target so the preview and a canvas drop are the same transform.
        public let target: DropTarget

        public init(pane: PaneID, target: DropTarget) {
            self.pane = pane
            self.target = target
        }
    }

    /// What a live drag would land in `tab`, or nil when nothing does: no
    /// drag, a drag aimed elsewhere, a subject that is not a pane, or a drop
    /// the planner refuses (a pane onto its own tab's handle, or onto its own
    /// mini pane). Keyed on the planned outcome rather than on the resolved
    /// target, so a drop that commits nothing previews nothing.
    public static func arrival(of subject: DragSubject?, onto target: DropTarget?, tab: TabID, model: SessionModel?) -> Arrival? {
        guard let target, let model, case .pane(let pane)? = subject,
              targetedTab(of: target, dragging: subject, model: model) == tab,
              let landing = canvasTarget(of: target, in: tab, model: model)
        else {
            return nil
        }
        return Arrival(pane: pane, target: landing)
    }

    /// The tab a grid drop is aimed at, whichever shape the target took: a
    /// whole thumbnail, or one of the mini panes drawn inside one. What the
    /// card and the thumbnail read to know they are the drop's target.
    ///
    /// Nil for a drop the planner refuses, which is the same gate the arrival
    /// preview passes through: a pane dropped on its own tab, or on its own
    /// mini pane, commits nothing and so marks nothing.
    public static func targetedTab(of target: DropTarget?, dragging subject: DragSubject?, model: SessionModel?) -> TabID? {
        guard let target, let subject, let model,
              case .success = plan(dragging: subject, onto: target, model: model)
        else {
            return nil
        }
        switch target {
        case .tabThumbnail(let tab):
            return tab
        case .paneEdge(let pane, _), .paneInterior(let pane):
            return model.panes[pane]?.tabID
        default:
            return nil
        }
    }

    /// Where a resolved grid target lands inside `tab`, as one of the canvas's
    /// own targets. A mini pane names itself; the tab's own handle names no
    /// pane, and herdr splits the tab's focused pane when a `pane.move` names
    /// a tab and no pane of it, keeping the target as the first child.
    private static func canvasTarget(of target: DropTarget, in tab: TabID, model: SessionModel) -> DropTarget? {
        switch target {
        case .tabThumbnail(let hit):
            guard hit == tab, let focused = model.layouts[tab]?.focusedPane else { return nil }
            return .paneEdge(focused, .right)
        case .paneEdge(let pane, _), .paneInterior(let pane):
            guard model.panes[pane]?.tabID == tab else { return nil }
            return target
        default:
            return nil
        }
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

    /// Every box of one thumbnail crossed into the thumbnail's own space,
    /// which is where a drop is hit-tested against them.
    public static func boxesInThumbnail(_ boxes: [Placed], stripHeight: CGFloat) -> [Placed] {
        boxes.map { Placed(pane: $0.pane, frame: boxInThumbnail($0.frame, stripHeight: stripHeight)) }
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
    /// by `DropPreview`, which is the transform the canvas previews a drop
    /// with, and the same geometry pass lays the result out.
    ///
    /// Without a tree the snapshot's own rects carry it: a `pane.move` only
    /// ever divides the one region it is aimed at, so dividing the target
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
        guard let landed = landed(arriving, in: layout) else {
            return CanvasGeometry.resolved(layout: layout, exported: exported, grid: grid, dividerThickness: gap).paneFrames
        }
        return CanvasGeometry.resolved(layout: landed, exported: nil, grid: grid, dividerThickness: gap).paneFrames
    }

    /// The snapshot the drop leaves behind, or nil when its target is not a
    /// pane of this layout.
    private static func landed(_ arriving: Arrival, in layout: LayoutSnapshot) -> LayoutSnapshot? {
        switch arriving.target {
        case .paneEdge(let targetPane, let edge):
            return dividing(targetPane, on: edge, for: arriving.pane, in: layout)
        case .paneInterior(let targetPane):
            guard targetPane != arriving.pane, let target = layout.panes.first(where: { $0.paneID == targetPane })
            else {
                return nil
            }
            // A pane of another tab has no rect here to trade with, and the
            // `pane.move` the plan sends divides the target's region instead,
            // target first.
            guard let moving = layout.panes.first(where: { $0.paneID == arriving.pane }) else {
                return dividing(targetPane, on: .right, for: arriving.pane, in: layout)
            }
            var preview = layout
            preview.panes = layout.panes.filter { $0.paneID != arriving.pane && $0.paneID != targetPane }
                + [
                    PaneRect(paneID: targetPane, focused: target.focused, rect: moving.rect),
                    PaneRect(paneID: arriving.pane, focused: moving.focused, rect: target.rect),
                ]
            return preview
        default:
            return nil
        }
    }

    /// `targetPane`'s own cell rect halved, the arriving pane taking the side
    /// `edge` names and the target keeping the other.
    private static func dividing(
        _ targetPane: PaneID, on edge: Edge, for arriving: PaneID, in layout: LayoutSnapshot
    ) -> LayoutSnapshot? {
        guard targetPane != arriving, let target = layout.panes.first(where: { $0.paneID == targetPane }) else {
            return nil
        }
        let direction: SplitDirection
        let arrivingLeads: Bool
        switch edge {
        case .left: direction = .right; arrivingLeads = true
        case .right: direction = .right; arrivingLeads = false
        case .top: direction = .down; arrivingLeads = true
        case .bottom: direction = .down; arrivingLeads = false
        }
        let regions = SplitTree.childRegions(of: target.rect, direction: direction, ratio: 0.5)
        var preview = layout
        preview.panes = layout.panes.filter { $0.paneID != arriving && $0.paneID != targetPane }
            + [
                PaneRect(paneID: targetPane, focused: target.focused, rect: arrivingLeads ? regions.second : regions.first),
                PaneRect(paneID: arriving, focused: false, rect: arrivingLeads ? regions.first : regions.second),
            ]
        return preview
    }
}
