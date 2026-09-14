import CoreGraphics

/// The rects a canvas drop would produce: the incoming pane's, and every
/// other pane's as the drop would leave it.
public struct DropPreviewFrames: Hashable, Sendable {
    public let incoming: CGRect
    /// Ordered top-to-bottom then left-to-right, so two equal layouts compare
    /// equal whatever order the tree walk produced them in. Empty when no
    /// exported tree was available and only the incoming rect could be
    /// derived.
    public let others: [CGRect]

    public init(incoming: CGRect, others: [CGRect]) {
        self.incoming = incoming
        self.others = others
    }
}

/// What the canvas would look like after a drop, as a split tree the ordinary
/// geometry pass can lay out: `CanvasGeometry(exportedRoot:area:tabID:grid:)`
/// turns the tree this produces into the previewed rects, so the preview and
/// the real layout are computed by the same code.
public enum DropPreview {
    /// The previewed frames for one drag frame, in the canvas's own space.
    /// `nil` unless a pane is being dragged onto a canvas target.
    ///
    /// The full post-drop layout needs herdr's own split tree; without one
    /// cached for this tab the incoming rect is still derived from the target
    /// frame alone, and `others` is empty rather than guessed at.
    public static func frames(
        target: DropTarget?,
        dragging subject: DragSubject?,
        layout: LayoutSnapshot,
        exported: ExportedLayoutDescription?,
        grid: CanvasGrid,
        dividerThickness: CGFloat
    ) -> DropPreviewFrames? {
        guard let target, case .pane(let paneID)? = subject else { return nil }
        if let exported, exported.tabID == layout.tabID,
           let previewRoot = root(exported.root, dropping: paneID, onto: target) {
            let geometry = CanvasGeometry(
                exportedRoot: previewRoot, area: layout.area, tabID: layout.tabID,
                grid: grid, dividerThickness: dividerThickness
            )
            guard let incoming = geometry.paneFrames[paneID] else { return nil }
            let others = geometry.paneFrames.filter { $0.key != paneID }.values
                .sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
            return DropPreviewFrames(incoming: incoming, others: Array(others))
        }
        let current = CanvasGeometry.resolved(
            layout: layout, exported: exported, grid: grid, dividerThickness: dividerThickness
        )
        switch target {
        case .paneEdge(let targetPane, let edge):
            guard targetPane != paneID, let frame = current.paneFrames[targetPane] else { return nil }
            return DropPreviewFrames(incoming: incomingRect(in: frame, edge: edge), others: [])
        case .paneInterior(let targetPane):
            guard targetPane != paneID, let frame = current.paneFrames[targetPane] else { return nil }
            return DropPreviewFrames(incoming: frame, others: [])
        case .tabStrip, .tabThumbnail, .workspaceThumbnail, .newTab, .newWorkspace, .workspaceRail:
            return nil
        }
    }

    /// `root` with `pane` lifted out of wherever it currently sits and
    /// re-landed on `target`, or `nil` when the target is not a canvas target,
    /// when the drop is degenerate (a pane onto itself), or when lifting the
    /// pane would empty the tree.
    ///
    /// A pane that is not in `root` at all (a cross-tab drag onto this canvas)
    /// lifts to a no-op and still lands, so the preview is the same shape
    /// either way.
    public static func root(_ root: ExportedLayoutNode, dropping pane: PaneID, onto target: DropTarget) -> ExportedLayoutNode? {
        switch target {
        case .paneEdge(let targetPane, let edge):
            guard targetPane != pane else { return nil }
            guard let lifted = removing(pane, from: root) else { return nil }
            guard contains(targetPane, in: lifted) else { return nil }
            return replacingLeaf(targetPane, in: lifted) { existing in
                split(incoming: .pane(ExportedLayoutPane(paneID: pane)), existing: existing, on: edge)
            }
        case .paneInterior(let targetPane):
            guard targetPane != pane else { return nil }
            guard contains(targetPane, in: root) else { return nil }
            // Same tab is a swap, so both leaves keep their place and only
            // the ids trade; a pane arriving from another tab has no leaf of
            // its own here and simply takes the target's.
            if contains(pane, in: root) {
                return swapping(pane, targetPane, in: root)
            }
            return replacingLeaf(targetPane, in: root) { _ in .pane(ExportedLayoutPane(paneID: pane)) }
        case .tabStrip, .tabThumbnail, .workspaceThumbnail, .newTab, .newWorkspace, .workspaceRail:
            return nil
        }
    }

    /// The half of `frame` a directional edge drop hands the incoming pane.
    /// The preview's fallback when no exported tree is cached for the tab, and
    /// the flash region for a committed edge drop.
    public static func incomingRect(in frame: CGRect, edge: Edge) -> CGRect {
        switch edge {
        case .left: return CGRect(x: frame.minX, y: frame.minY, width: frame.width / 2, height: frame.height)
        case .right: return CGRect(x: frame.midX, y: frame.minY, width: frame.width / 2, height: frame.height)
        case .top: return CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height / 2)
        case .bottom: return CGRect(x: frame.minX, y: frame.midY, width: frame.width, height: frame.height / 2)
        }
    }

    private static func split(incoming: ExportedLayoutNode, existing: ExportedLayoutNode, on edge: Edge) -> ExportedLayoutNode {
        switch edge {
        case .left: return .split(direction: .right, ratio: 0.5, first: incoming, second: existing)
        case .right: return .split(direction: .right, ratio: 0.5, first: existing, second: incoming)
        case .top: return .split(direction: .down, ratio: 0.5, first: incoming, second: existing)
        case .bottom: return .split(direction: .down, ratio: 0.5, first: existing, second: incoming)
        }
    }

    static func contains(_ pane: PaneID, in node: ExportedLayoutNode) -> Bool {
        switch node {
        case .pane(let leaf): return leaf.paneID == pane
        case .split(_, _, let first, let second): return contains(pane, in: first) || contains(pane, in: second)
        }
    }

    /// `node` without `pane`: a split that loses one child collapses into the
    /// other, matching what herdr itself does when a pane leaves a tab.
    /// `nil` means the whole subtree is gone.
    static func removing(_ pane: PaneID, from node: ExportedLayoutNode) -> ExportedLayoutNode? {
        switch node {
        case .pane(let leaf):
            return leaf.paneID == pane ? nil : node
        case .split(let direction, let ratio, let first, let second):
            let keptFirst = removing(pane, from: first)
            let keptSecond = removing(pane, from: second)
            switch (keptFirst, keptSecond) {
            case (nil, nil): return nil
            case (let only?, nil), (nil, let only?): return only
            case (let a?, let b?): return .split(direction: direction, ratio: ratio, first: a, second: b)
            }
        }
    }

    static func replacingLeaf(
        _ pane: PaneID,
        in node: ExportedLayoutNode,
        with replacement: (ExportedLayoutNode) -> ExportedLayoutNode
    ) -> ExportedLayoutNode {
        switch node {
        case .pane(let leaf):
            return leaf.paneID == pane ? replacement(node) : node
        case .split(let direction, let ratio, let first, let second):
            return .split(
                direction: direction,
                ratio: ratio,
                first: replacingLeaf(pane, in: first, with: replacement),
                second: replacingLeaf(pane, in: second, with: replacement)
            )
        }
    }

    static func swapping(_ a: PaneID, _ b: PaneID, in node: ExportedLayoutNode) -> ExportedLayoutNode {
        switch node {
        case .pane(let leaf):
            guard let paneID = leaf.paneID, paneID == a || paneID == b else { return node }
            return .pane(ExportedLayoutPane(paneID: paneID == a ? b : a, label: leaf.label, cwd: leaf.cwd))
        case .split(let direction, let ratio, let first, let second):
            return .split(
                direction: direction,
                ratio: ratio,
                first: swapping(a, b, in: first),
                second: swapping(a, b, in: second)
            )
        }
    }
}

/// The on-screen region a drop would land in: what flashes for 700ms once the
/// drop commits, and where the ghost settles to. `nil` when the surfaces do
/// not carry a frame for the target (a tab or workspace that is not on screen).
public func dropTargetRect(for target: DropTarget, surfaces: DropSurfaces) -> CGRect? {
    switch target {
    case .paneInterior(let pane):
        return surfaces.canvas.paneFrames[pane]
    case .paneEdge(let pane, let edge):
        guard let frame = surfaces.canvas.paneFrames[pane] else { return nil }
        return DropPreview.incomingRect(in: frame, edge: edge)
    case .tabThumbnail(let tab):
        return surfaces.tabFrames.first { $0.id == tab }?.frame
    case .workspaceThumbnail(let workspace):
        return surfaces.workspaceFrames.first { $0.id == workspace }?.frame
    case .newTab:
        return surfaces.newTabZone
    case .newWorkspace:
        return surfaces.newWorkspaceZone
    case .tabStrip(_, let insertIndex):
        guard let container = surfaces.stripFrame else { return nil }
        return InsertionBarGeometry.bar(
            atInsertIndex: insertIndex, items: surfaces.tabFrames.map(\.frame), container: container, axis: .vertical
        )
    case .workspaceRail(let insertIndex):
        guard let container = surfaces.railFrame else { return nil }
        return InsertionBarGeometry.bar(
            atInsertIndex: insertIndex, items: surfaces.workspaceFrames.map(\.frame), container: container, axis: .horizontal
        )
    }
}
