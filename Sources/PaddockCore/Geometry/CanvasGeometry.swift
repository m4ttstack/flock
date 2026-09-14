import CoreGraphics

public enum Edge: CaseIterable, Sendable {
    case top, bottom, left, right
}

public struct DividerHandle: Equatable, Sendable {
    public let tabID: TabID
    public let path: [Bool]
    public let frame: CGRect
    public let direction: SplitDirection
}

/// Where a tab's cell grid sits on the canvas: the tab's `area` stretched to
/// fill the canvas, so the panes always tile it exactly.
///
/// Every frame's four edges are snapped to whole device pixels. `phase` is
/// the canvas's own origin in the window, so a frame is snapped where it
/// actually lands on screen rather than where it would land if the canvas
/// began at the window's corner: libghostty composites a surface at the
/// origin the box gives it, and a fractional device pixel there resamples
/// every glyph in the pane.
public struct CanvasGrid: Equatable, Sendable {
    public let canvas: CGSize
    public let phase: CGPoint
    public let displayScale: CGFloat

    public init(canvas: CGSize, phase: CGPoint = .zero, displayScale: CGFloat = 2) {
        self.canvas = canvas
        self.phase = phase
        self.displayScale = displayScale > 0 ? displayScale : 1
    }

    /// `rect` (in herdr cells, relative to `area`) as a canvas frame. Both
    /// EDGES of each axis are snapped, never the origin and the size
    /// independently: adjacent panes share an edge, and snapping that shared
    /// edge once is what keeps them abutting with no seam and no overlap.
    public func frame(for rect: CellRect, area: CellRect) -> CGRect {
        guard area.width > 0, area.height > 0 else { return .zero }
        let left = snap(canvas.width * CGFloat(rect.x - area.x) / CGFloat(area.width), phase: phase.x)
        let right = snap(canvas.width * CGFloat(rect.x - area.x + rect.width) / CGFloat(area.width), phase: phase.x)
        let top = snap(canvas.height * CGFloat(rect.y - area.y) / CGFloat(area.height), phase: phase.y)
        let bottom = snap(canvas.height * CGFloat(rect.y - area.y + rect.height) / CGFloat(area.height), phase: phase.y)
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    private func snap(_ value: CGFloat, phase: CGFloat) -> CGFloat {
        ((value + phase) * displayScale).rounded() / displayScale - phase
    }
}

/// The whole-cell terminal grid a pane box's content area can hold, and the
/// exact size that grid occupies.
public enum SurfaceGrid {
    /// Floors both axes: the sub-cell remainder stays as padding inside the
    /// box, so a partial cell is never rendered. Never below 1x1 -- herdr
    /// clamps a pane to its own floor anyway, and a zero-dimension surface
    /// has no meaning.
    public static func fit(inner: CGSize, cell: CGSize) -> (cols: Int, rows: Int, size: CGSize) {
        guard cell.width > 0, cell.height > 0 else { return (1, 1, .zero) }
        let cols = max(1, Int((inner.width / cell.width).rounded(.down)))
        let rows = max(1, Int((inner.height / cell.height).rounded(.down)))
        return (cols, rows, CGSize(width: CGFloat(cols) * cell.width, height: CGFloat(rows) * cell.height))
    }
}

public struct CanvasGeometry: Equatable, Sendable {
    public let paneFrames: [PaneID: CGRect]
    public let dividers: [DividerHandle]

    /// The render path's single entry point: reads `exported` (herdr's own
    /// split tree) when it names this tab, and falls back to rect derivation
    /// otherwise -- an export the coordinator never fetched, or one that
    /// failed and got flagged for fallback, both read as `exported == nil`
    /// or tab-mismatched here.
    public static func resolved(
        layout: LayoutSnapshot,
        exported: ExportedLayoutDescription?,
        grid: CanvasGrid,
        dividerThickness: CGFloat = 6
    ) -> CanvasGeometry {
        if let exported, exported.tabID == layout.tabID {
            return CanvasGeometry(exportedRoot: exported.root, area: layout.area, tabID: layout.tabID, grid: grid, dividerThickness: dividerThickness)
        }
        return CanvasGeometry(layout: layout, grid: grid, dividerThickness: dividerThickness)
    }

    public init(layout: LayoutSnapshot, grid: CanvasGrid, dividerThickness: CGFloat = 6) {
        let area = layout.area
        guard area.width > 0, area.height > 0 else {
            paneFrames = Dictionary(uniqueKeysWithValues: layout.panes.map { ($0.paneID, .zero) })
            dividers = []
            return
        }

        func scale(_ rect: CellRect) -> CGRect {
            grid.frame(for: rect, area: area)
        }

        paneFrames = Dictionary(uniqueKeysWithValues: layout.panes.map { ($0.paneID, scale($0.rect)) })
        dividers = CanvasGeometry.dividerHandles(
            splits: layout.splits,
            area: area,
            tabID: layout.tabID,
            scale: scale,
            thickness: dividerThickness
        )
    }

    /// Builds geometry from herdr's own split tree (`layout.export`) instead
    /// of reconstructing nesting by rect containment: the tree already gives
    /// parent/child order, so paths and regions fall out of a direct walk.
    /// `area` is the tab's cell-grid rect (from the tab's `LayoutSnapshot`,
    /// which `layout.export` does not itself carry).
    public init(exportedRoot root: ExportedLayoutNode, area: CellRect, tabID: TabID, grid: CanvasGrid, dividerThickness: CGFloat = 6) {
        guard area.width > 0, area.height > 0 else {
            paneFrames = [:]
            dividers = []
            return
        }

        func scale(_ rect: CellRect) -> CGRect {
            grid.frame(for: rect, area: area)
        }

        var paneFrames: [PaneID: CGRect] = [:]
        var dividers: [DividerHandle] = []
        CanvasGeometry.walk(
            root,
            rect: area,
            path: [],
            tabID: tabID,
            scale: scale,
            thickness: dividerThickness,
            paneFrames: &paneFrames,
            dividers: &dividers
        )
        self.paneFrames = paneFrames
        self.dividers = dividers
    }

    private static func walk(
        _ node: ExportedLayoutNode,
        rect: CellRect,
        path: [Bool],
        tabID: TabID,
        scale: (CellRect) -> CGRect,
        thickness: CGFloat,
        paneFrames: inout [PaneID: CGRect],
        dividers: inout [DividerHandle]
    ) {
        switch node {
        case .pane(let pane):
            guard let paneID = pane.paneID else { return }
            paneFrames[paneID] = scale(rect)
        case .split(let direction, let ratio, let first, let second):
            let (firstRegion, secondRegion) = childRegions(of: rect, direction: direction, ratio: ratio)
            dividers.append(DividerHandle(
                tabID: tabID,
                path: path,
                frame: dividerFrame(direction: direction, ratio: ratio, fullFrame: scale(rect), thickness: thickness),
                direction: direction
            ))
            walk(first, rect: firstRegion, path: path + [false], tabID: tabID, scale: scale, thickness: thickness, paneFrames: &paneFrames, dividers: &dividers)
            walk(second, rect: secondRegion, path: path + [true], tabID: tabID, scale: scale, thickness: thickness, paneFrames: &paneFrames, dividers: &dividers)
        }
    }

    /// Splits nest by rect containment, not array order: the root is the split
    /// spanning the full layout area; a split contained in a parent's first-child
    /// region gets `false` appended to the parent's path, the second-child region
    /// gets `true`. A split whose parent cannot be resolved this way is dropped
    /// rather than guessed at. Fixture-verified fallback only: the render path
    /// reads `layout.export`'s tree (see `init(exportedRoot:...)`); this stays
    /// live as the cross-check in `CanvasGeometryTests` and as the coordinator's
    /// failure fallback.
    private static func dividerHandles(
        splits: [SplitInfo],
        area: CellRect,
        tabID: TabID,
        scale: (CellRect) -> CGRect,
        thickness: CGFloat
    ) -> [DividerHandle] {
        guard let root = splits.first(where: { $0.rect == area }) ?? splits.max(by: { cellArea($0.rect) < cellArea($1.rect) }) else {
            return []
        }

        var paths: [String: [Bool]] = [root.id: []]
        var remaining = splits.filter { $0.id != root.id }
        var madeProgress = true
        while madeProgress && !remaining.isEmpty {
            madeProgress = false
            for split in remaining {
                guard let parent = splits.first(where: { candidate in
                    paths[candidate.id] != nil
                        && (contains(candidate.firstChildRegion, split.rect) || contains(candidate.secondChildRegion, split.rect))
                }), let parentPath = paths[parent.id] else { continue }
                let branch = contains(parent.secondChildRegion, split.rect)
                paths[split.id] = parentPath + [branch]
                remaining.removeAll { $0.id == split.id }
                madeProgress = true
            }
        }

        return splits.compactMap { split in
            guard let path = paths[split.id] else { return nil }
            let full = scale(split.rect)
            return DividerHandle(
                tabID: tabID,
                path: path,
                frame: dividerFrame(direction: split.direction, ratio: Double(split.ratio), fullFrame: full, thickness: thickness),
                direction: split.direction
            )
        }
    }

    private static func dividerFrame(direction: SplitDirection, ratio: Double, fullFrame: CGRect, thickness: CGFloat) -> CGRect {
        switch direction {
        case .right:
            let boundaryX = fullFrame.minX + CGFloat(ratio) * fullFrame.width
            return CGRect(x: boundaryX - thickness / 2, y: fullFrame.minY, width: thickness, height: fullFrame.height)
        case .down:
            let boundaryY = fullFrame.minY + CGFloat(ratio) * fullFrame.height
            return CGRect(x: fullFrame.minX, y: boundaryY - thickness / 2, width: fullFrame.width, height: thickness)
        }
    }

    /// Shared by both derivations: splits a rect into its two child regions
    /// for a given direction and ratio, rounding the same way a real herdr
    /// tab's cell grid would.
    fileprivate static func childRegions(of rect: CellRect, direction: SplitDirection, ratio: Double) -> (first: CellRect, second: CellRect) {
        switch direction {
        case .right:
            let firstWidth = Int((Double(rect.width) * ratio).rounded())
            let first = CellRect(x: rect.x, y: rect.y, width: firstWidth, height: rect.height)
            let second = CellRect(x: rect.x + firstWidth, y: rect.y, width: rect.width - firstWidth, height: rect.height)
            return (first, second)
        case .down:
            let firstHeight = Int((Double(rect.height) * ratio).rounded())
            let first = CellRect(x: rect.x, y: rect.y, width: rect.width, height: firstHeight)
            let second = CellRect(x: rect.x, y: rect.y + firstHeight, width: rect.width, height: rect.height - firstHeight)
            return (first, second)
        }
    }

    private static func cellArea(_ rect: CellRect) -> Int { rect.width * rect.height }

    private static func contains(_ region: CellRect, _ rect: CellRect) -> Bool {
        rect.x >= region.x && rect.y >= region.y
            && rect.x + rect.width <= region.x + region.width
            && rect.y + rect.height <= region.y + region.height
    }
}

private extension SplitInfo {
    var firstChildRegion: CellRect {
        CanvasGeometry.childRegions(of: rect, direction: direction, ratio: Double(ratio)).first
    }

    var secondChildRegion: CellRect {
        CanvasGeometry.childRegions(of: rect, direction: direction, ratio: Double(ratio)).second
    }
}
