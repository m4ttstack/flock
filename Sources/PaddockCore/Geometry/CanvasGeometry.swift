import CoreGraphics

public enum Edge: CaseIterable, Sendable {
    case top, bottom, left, right
}

public struct DividerHandle: Equatable, Sendable {
    public let tabID: TabID
    public let path: [Bool]
    public let frame: CGRect
    public let direction: SplitDirection
    /// The full region this divider's own boundary moves within -- both
    /// children's combined extent, before the gutter is carved out of it.
    /// The same rect the two children were scaled within, so a
    /// pointer-to-ratio translation measured against this can never drift
    /// from wherever the two children actually render, cell rounding
    /// included.
    public let regionFrame: CGRect
    /// The along-axis cell count of `regionFrame` -- columns for `.right`,
    /// rows for `.down`. What a ratio must be weighed against to keep both
    /// children at or above herdr's own per-pane floor (`rows.max(2)`,
    /// `cols.max(4)` in `resize`): herdr enlarges an undersized pane
    /// silently rather than rejecting the ratio that produced it, so
    /// paddock has to keep the ratio honest on its own side.
    public let cellExtent: Int
}

extension DividerHandle {
    /// Whether this divider paints (and resizes) as a vertical line -- a
    /// left/right split, dragged horizontally -- rather than a horizontal
    /// one. What its own paint geometry, live-ratio offset, and resize
    /// cursor all key off, so no caller restates `direction == .right`.
    public var isVerticalLine: Bool { direction == .right }

    /// `frame` widened from the drawn gutter to `thickness`, same
    /// centerline (`frame` is already centered on the split boundary),
    /// same length -- the divider's actual hit region, distinct from what
    /// it paints. Widening only the cross-axis keeps the along-axis reach
    /// exactly what `frame` already covers.
    public func hitBand(thickness: CGFloat) -> CGRect {
        isVerticalLine
            ? frame.insetBy(dx: -(thickness - frame.width) / 2, dy: 0)
            : frame.insetBy(dx: 0, dy: -(thickness - frame.height) / 2)
    }
}

/// The gutter between panes, its grab band and its visible handle. The band
/// is bounded by `PaneCellView`'s own chrome: a vertical divider borders each
/// neighbor's 10pt leading/trailing content inset, a horizontal one borders
/// the 8pt bottom inset above and the 8pt legend band plus 12pt top inset
/// below, each past half the gutter. `DividerBandTests` pins that the band's
/// half stays inside the tightest of them.
public enum DividerBand {
    /// The drawn space between two pane boxes. Every pane box and the drop
    /// preview inset by half of it, so this is the one value to change.
    public static let gutter: CGFloat = 12
    /// The grab band centered on the gutter. Half of it must stay under the
    /// smallest chrome margin a neighbor carries past its half-gutter (its
    /// 8pt bottom inset), or a press could land on terminal text.
    public static let thickness: CGFloat = 24
    /// The visible handle: a capsule this thick, a fifth of the divider's
    /// length, centered along it.
    public static let handleThickness: CGFloat = 3
    public static let handleLengthFraction: CGFloat = 0.2
    public static let handleMinimumLength: CGFloat = 28

    public static func handleLength(forDividerLength length: CGFloat) -> CGFloat {
        min(length, max(handleMinimumLength, length * handleLengthFraction))
    }
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
    /// herdr's own floor for a pane (`rows.max(2)`, `cols.max(4)` in
    /// `src/pane.rs`). Paddock must never lay a surface out at, or ask for, a
    /// grid smaller than this: herdr would silently give the real pane the
    /// floor instead, leaving the surface rendering a grid the pane does not
    /// have and `MouseForwarding`'s cell clamp reading the wrong one.
    public static let minimumCols = 4
    public static let minimumRows = 2

    /// Floors both axes: the sub-cell remainder stays as padding inside the
    /// box, so a partial cell is never rendered.
    public static func fit(inner: CGSize, cell: CGSize) -> (cols: Int, rows: Int, size: CGSize) {
        guard cell.width > 0, cell.height > 0 else { return (minimumCols, minimumRows, .zero) }
        let cols = max(minimumCols, Int((inner.width / cell.width).rounded(.down)))
        let rows = max(minimumRows, Int((inner.height / cell.height).rounded(.down)))
        return (cols, rows, CGSize(width: CGFloat(cols) * cell.width, height: CGFloat(rows) * cell.height))
    }
}

/// One pane's box inside the layout frame the canvas gave it.
public enum PaneBox {
    /// Inset by half the divider gutter on every side, so two adjacent boxes
    /// leave a full gutter between them. The size is clamped at zero: a frame
    /// narrower or shorter than the gutter (enough splits in a small window,
    /// or a transient zero-size layout pass) would otherwise hand SwiftUI a
    /// negative frame. A whole-point gutter keeps the snapped origin snapped.
    public static func frame(in frame: CGRect, dividerThickness: CGFloat) -> CGRect {
        let inset = dividerThickness / 2
        return CGRect(
            x: frame.minX + inset,
            y: frame.minY + inset,
            width: max(0, frame.width - dividerThickness),
            height: max(0, frame.height - dividerThickness)
        )
    }
}

public struct CanvasGeometry: Equatable, Sendable {
    public let paneFrames: [PaneID: CGRect]
    public let dividers: [DividerHandle]

    /// No panes and no dividers: what hit-testing resolves against when no
    /// tab is selected, so a drag still has surfaces to ask.
    public static let empty = CanvasGeometry(paneFrames: [:], dividers: [])

    private init(paneFrames: [PaneID: CGRect], dividers: [DividerHandle]) {
        self.paneFrames = paneFrames
        self.dividers = dividers
    }

    /// The same geometry translated into an outer space: the canvas lays its
    /// frames out in its own local space, and drop hit-testing works in the
    /// window's, so `delta` is the canvas's own origin there.
    public func offset(by delta: CGPoint) -> CanvasGeometry {
        CanvasGeometry(
            paneFrames: paneFrames.mapValues { $0.offsetBy(dx: delta.x, dy: delta.y) },
            dividers: dividers.map {
                DividerHandle(
                    tabID: $0.tabID, path: $0.path, frame: $0.frame.offsetBy(dx: delta.x, dy: delta.y), direction: $0.direction,
                    regionFrame: $0.regionFrame.offsetBy(dx: delta.x, dy: delta.y), cellExtent: $0.cellExtent
                )
            }
        )
    }

    /// The render path's single entry point: reads `exported` (herdr's own
    /// split tree) when it names this tab, and falls back to rect derivation
    /// otherwise -- an export the coordinator never fetched, or one that
    /// failed and got flagged for fallback, both read as `exported == nil`
    /// or tab-mismatched here. `liveRatioOverride` substitutes one split's
    /// ratio during the walk, for a divider drag's own live preview -- see
    /// `walk`'s own doc comment for why only the exported-tree path can
    /// actually move pane frames from it.
    public static func resolved(
        layout: LayoutSnapshot,
        exported: ExportedLayoutDescription?,
        grid: CanvasGrid,
        dividerThickness: CGFloat = 6,
        liveRatioOverride: (path: [Bool], ratio: Double)? = nil
    ) -> CanvasGeometry {
        if let exported, exported.tabID == layout.tabID {
            return CanvasGeometry(
                exportedRoot: exported.root, area: layout.area, tabID: layout.tabID, grid: grid,
                dividerThickness: dividerThickness, liveRatioOverride: liveRatioOverride
            )
        }
        return CanvasGeometry(layout: layout, grid: grid, dividerThickness: dividerThickness, liveRatioOverride: liveRatioOverride)
    }

    public init(layout: LayoutSnapshot, grid: CanvasGrid, dividerThickness: CGFloat = 6, liveRatioOverride: (path: [Bool], ratio: Double)? = nil) {
        let area = layout.area
        guard area.width > 0, area.height > 0 else {
            paneFrames = Dictionary(uniqueKeysWithValues: layout.panes.map { ($0.paneID, .zero) })
            dividers = []
            return
        }

        func scale(_ rect: CellRect) -> CGRect {
            grid.frame(for: rect, area: area)
        }

        // Pane rects here are herdr's own literal, already-resolved values
        // (`PaneRect.rect`), never derived from a split's ratio -- so unlike
        // the exported-tree walk below, `liveRatioOverride` cannot move a
        // pane frame in this fallback path. Only the divider's own drawn
        // position reflects it.
        paneFrames = Dictionary(uniqueKeysWithValues: layout.panes.map { ($0.paneID, scale($0.rect)) })
        dividers = CanvasGeometry.dividerHandles(
            splits: layout.splits,
            area: area,
            tabID: layout.tabID,
            scale: scale,
            thickness: dividerThickness,
            override: liveRatioOverride
        )
    }

    /// Builds geometry from herdr's own split tree (`layout.export`) instead
    /// of reconstructing nesting by rect containment: the tree already gives
    /// parent/child order, so paths and regions fall out of a direct walk.
    /// `area` is the tab's cell-grid rect (from the tab's `LayoutSnapshot`,
    /// which `layout.export` does not itself carry).
    public init(
        exportedRoot root: ExportedLayoutNode, area: CellRect, tabID: TabID, grid: CanvasGrid, dividerThickness: CGFloat = 6,
        liveRatioOverride: (path: [Bool], ratio: Double)? = nil
    ) {
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
            override: liveRatioOverride,
            paneFrames: &paneFrames,
            dividers: &dividers
        )
        self.paneFrames = paneFrames
        self.dividers = dividers
    }

    /// `override` substitutes the ratio of the split whose own `path`
    /// matches it -- every pane and divider beneath that split then falls
    /// out of the SAME recursion with the new regions, which is what makes
    /// this a true live footprint preview rather than a redrawn line: the
    /// tree only carries ratios and parent/child order, never absolute
    /// rects, so a changed ratio anywhere propagates to every descendant for
    /// free.
    private static func walk(
        _ node: ExportedLayoutNode,
        rect: CellRect,
        path: [Bool],
        tabID: TabID,
        scale: (CellRect) -> CGRect,
        thickness: CGFloat,
        override: (path: [Bool], ratio: Double)?,
        paneFrames: inout [PaneID: CGRect],
        dividers: inout [DividerHandle]
    ) {
        switch node {
        case .pane(let pane):
            guard let paneID = pane.paneID else { return }
            paneFrames[paneID] = scale(rect)
        case .split(let direction, let nodeRatio, let first, let second):
            let ratio = override?.path == path ? override!.ratio : nodeRatio
            let (firstRegion, secondRegion) = childRegions(of: rect, direction: direction, ratio: ratio)
            let full = scale(rect)
            dividers.append(DividerHandle(
                tabID: tabID,
                path: path,
                frame: dividerFrame(direction: direction, firstChild: scale(firstRegion), fullFrame: full, thickness: thickness),
                direction: direction,
                regionFrame: full,
                cellExtent: direction == .right ? rect.width : rect.height
            ))
            walk(first, rect: firstRegion, path: path + [false], tabID: tabID, scale: scale, thickness: thickness, override: override, paneFrames: &paneFrames, dividers: &dividers)
            walk(second, rect: secondRegion, path: path + [true], tabID: tabID, scale: scale, thickness: thickness, override: override, paneFrames: &paneFrames, dividers: &dividers)
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
        thickness: CGFloat,
        override: (path: [Bool], ratio: Double)?
    ) -> [DividerHandle] {
        let paths = splitPaths(splits: splits, area: area)

        return splits.compactMap { split in
            guard let path = paths[split.id] else { return nil }
            // Only the divider's own drawn position can honor the override
            // here (see `init(layout:...)`'s own comment on why pane frames
            // cannot).
            let ratio = override?.path == path ? override!.ratio : Double(split.ratio)
            let full = scale(split.rect)
            let firstChild = scale(childRegions(of: split.rect, direction: split.direction, ratio: ratio).first)
            return DividerHandle(
                tabID: tabID,
                path: path,
                frame: dividerFrame(direction: split.direction, firstChild: firstChild, fullFrame: full, thickness: thickness),
                direction: split.direction,
                regionFrame: full,
                cellExtent: split.direction == .right ? split.rect.width : split.rect.height
            )
        }
    }

    /// Resolves every split's own path. Primary source: herdr puts the path
    /// on the wire itself, in the split's own `id` (`split_path_id` in
    /// `herdr/src/app/api/panes.rs`) -- `split_<idx>_root` for the root
    /// (empty path), `split_<idx>_<digits>` otherwise, `<digits>` being
    /// exactly the `[Bool]` path with no separator, `1` for a `true`
    /// (second-child) branch and `0` for `false`. `pathFromSplitID` parses
    /// this; polarity is pinned against `set_ratio_at`
    /// (`herdr/src/layout.rs`), which descends into `second` when
    /// `path[0]` and `first` otherwise -- the identical convention this
    /// module already uses for `path + [true]`/`path + [false]`
    /// (`walk`/`childRegions`), confirmed by a real-geometry test, not
    /// merely asserted. If EVERY split's id parses this way (true of any
    /// real herdr snapshot, whose ids all come from the same function),
    /// this is the whole answer: no tree walk, so nothing to bound.
    ///
    /// Fallback, for anything whose ids do not all parse (a fixture using
    /// its own literal ids, say): descend from the root, matching each
    /// split's OWN two computed child regions (`childRegions`, its own
    /// direction/ratio/rect) against a split whose rect equals one exactly,
    /// recursing only into a match. Deliberately NOT "does some
    /// already-resolved split's region contain this rect": containment is
    /// transitive, so a grandchild's rect sits inside its GRANDPARENT's own
    /// child region too, and a scan over every resolved split can find the
    /// grandparent before the true parent ever gets a chance, colliding two
    /// different splits onto the same path. A `visited` set bounds the walk
    /// regardless of how the tree is shaped: a ratio that rounds one child
    /// to zero cells makes the OTHER child's rect equal the parent's own,
    /// and with two such splits pointing at each other's rect (both
    /// degenerate, each one row short of the other), a bound keyed only on
    /// "not myself" still lets A resolve to B resolve to A resolve to B
    /// forever -- `visited` catches every step back to ANY split already on
    /// the path, not only the immediately previous one, so the walk is
    /// bounded by the tree's total split count regardless of cycle length.
    /// A split whose parent cannot be resolved this way is dropped rather
    /// than guessed at.
    ///
    /// Module-internal rather than `CanvasGeometry`'s own private detail:
    /// `HerdrStore`'s `setSplitRatio` prediction resolves the identical tree
    /// for the identical reason, and the two must resolve it the SAME way
    /// -- a caller commits a path this exact function produced, so the
    /// store's own prediction has to recognize it.
    static func splitPaths(splits: [SplitInfo], area: CellRect) -> [String: [Bool]] {
        if let fromIDs = pathsFromSplitIDs(splits) {
            return fromIDs
        }
        return structuralSplitPaths(splits: splits, area: area)
    }

    /// `nil` the moment any split's id does not match herdr's own
    /// `split_path_id` shape -- a partial parse is not trustworthy, since a
    /// caller-supplied id scheme that coincidentally matches for SOME
    /// splits gives no reason to believe it means the same thing for all of
    /// them.
    private static func pathsFromSplitIDs(_ splits: [SplitInfo]) -> [String: [Bool]]? {
        var paths: [String: [Bool]] = [:]
        var seenPaths: Set<[Bool]> = []
        for split in splits {
            guard let path = pathFromSplitID(split.id) else { return nil }
            // Unreachable against a real herdr snapshot (its own ids are
            // unique by construction), but two DIFFERENT split ids parsing
            // to the SAME path means this snapshot's id scheme is not
            // trustworthy for this purpose after all -- decline the whole
            // primary path rather than let two splits collide once a
            // caller (`HerdrStore.predictedLayout`) turns paths into
            // dictionary keys, the same "decline over guess" this file's
            // structural fallback already practices.
            guard seenPaths.insert(path).inserted else { return nil }
            paths[split.id] = path
        }
        return paths
    }

    private static func pathFromSplitID(_ id: String) -> [Bool]? {
        let parts = id.split(separator: "_", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "split", !parts[1].isEmpty else { return nil }
        if parts[2] == "root" { return [] }
        guard !parts[2].isEmpty else { return nil }
        var path: [Bool] = []
        path.reserveCapacity(parts[2].count)
        for character in parts[2] {
            switch character {
            case "0": path.append(false)
            case "1": path.append(true)
            default: return nil
            }
        }
        return path
    }

    private static func structuralSplitPaths(splits: [SplitInfo], area: CellRect) -> [String: [Bool]] {
        guard let root = splits.first(where: { $0.rect == area }) ?? splits.max(by: { cellArea($0.rect) < cellArea($1.rect) }) else {
            return [:]
        }

        var paths: [String: [Bool]] = [:]
        var visited: Set<String> = []
        func descend(_ split: SplitInfo, path: [Bool]) {
            guard !visited.contains(split.id) else { return }
            visited.insert(split.id)
            paths[split.id] = path
            let (first, second) = childRegions(of: split.rect, direction: split.direction, ratio: split.ratio)
            // Excluding `split.id` itself is what lets a degenerate split
            // (one child rounds to zero cells, so the OTHER child's rect
            // equals this split's own) find its true distinct sibling there
            // instead of matching itself -- `visited` alone would just stop
            // one step later, having silently dropped that sibling instead
            // of resolving it.
            if let firstChild = splits.first(where: { $0.id != split.id && $0.rect == first }) {
                descend(firstChild, path: path + [false])
            }
            if let secondChild = splits.first(where: { $0.id != split.id && $0.rect == second }) {
                descend(secondChild, path: path + [true])
            }
        }
        descend(root, path: [])
        return paths
    }

    /// Centered on the edge the first child's SCALED region actually ends
    /// at, never on `ratio * extent`: the panes are laid out from whole-cell
    /// child regions, so a divider drawn at the raw ratio sits up to a cell
    /// away from the gap the two pane boxes leave, visibly off-center in it.
    private static func dividerFrame(direction: SplitDirection, firstChild: CGRect, fullFrame: CGRect, thickness: CGFloat) -> CGRect {
        switch direction {
        case .right:
            return CGRect(x: firstChild.maxX - thickness / 2, y: fullFrame.minY, width: thickness, height: fullFrame.height)
        case .down:
            return CGRect(x: fullFrame.minX, y: firstChild.maxY - thickness / 2, width: fullFrame.width, height: thickness)
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
}
