import CoreGraphics

/// One tab strip item's on-screen frame, in strip order.
public struct TabItemFrame: Equatable, Sendable {
    public let id: TabID
    public let frame: CGRect

    public init(id: TabID, frame: CGRect) {
        self.id = id
        self.frame = frame
    }
}

/// One workspace rail item's on-screen frame, in rail order.
public struct WorkspaceItemFrame: Equatable, Sendable {
    public let id: WorkspaceID
    public let frame: CGRect

    public init(id: WorkspaceID, frame: CGRect) {
        self.id = id
        self.frame = frame
    }
}

/// The tabs one card of the grid draws, in the order it draws them, each
/// with the slot it occupies.
///
/// A resting card draws a PREFIX of its workspace's tabs, so a gap counted
/// over these cells names an index into the workspace's own tab list as well,
/// which is what `moveTab` takes.
public struct GridCardTabs: Equatable, Sendable {
    public let workspace: WorkspaceID
    public let tabs: [TabItemFrame]

    public init(workspace: WorkspaceID, tabs: [TabItemFrame]) {
        self.workspace = workspace
        self.tabs = tabs
    }
}

/// The All Workspaces grid while it covers the window, every frame in the
/// drag space. `viewport` is the grid's scroll view: a thumbnail or tile
/// scrolled out of it is not there to hit.
///
/// `cards` are the whole workspace cards, which contain their own thumbnails
/// and tiles. A card's "empty space" is not a frame of its own: it is
/// whatever of the card the thumbnails and tiles do not cover, which is why
/// the card is hit-tested last.
///
/// `tiles` is the one tile a card shows, "+N" at rest and "fewer" once
/// expanded. Neither takes a drop: both read as controls, so a release on
/// either springs back rather than making a tab behind them.
public struct GridDropSurfaces: Equatable, Sendable {
    public let viewport: CGRect
    public let thumbnails: [TabItemFrame]
    public let tiles: [WorkspaceItemFrame]
    public let cards: [WorkspaceItemFrame]
    /// Where a card is previewing the tab a drop on its empty space will
    /// create. Never hit-tested: the card behind it is what answers, so a
    /// release on the placeholder is a release on the card. It is the rect
    /// that drop actually LANDS in, which is what a committed drop settles
    /// and flashes on, in place of the whole card.
    public let newTabSlots: [WorkspaceItemFrame]
    /// The same thumbnails, grouped by the card drawing them and kept in card
    /// order: what a tab reordered inside its own card is placed among.
    public let cardTabs: [GridCardTabs]

    public init(
        viewport: CGRect, thumbnails: [TabItemFrame], tiles: [WorkspaceItemFrame], cards: [WorkspaceItemFrame],
        newTabSlots: [WorkspaceItemFrame] = [], cardTabs: [GridCardTabs] = []
    ) {
        self.viewport = viewport
        self.thumbnails = thumbnails
        self.tiles = tiles
        self.cards = cards
        self.newTabSlots = newTabSlots
        self.cardTabs = cardTabs
    }
}

/// Every on-screen surface `resolveDropTarget` can hit-test against for one
/// frame of a drag gesture.
///
/// `grid` is set only while the grid covers the window. The rail, strip and
/// canvas keep their last reported frames underneath it, so a set `grid` is
/// the whole answer and those frames are never consulted.
///
/// `stripWorkspace` is the workspace `tabFrames` belongs to: `DropTarget`'s
/// `.tabStrip`/`.newTab` cases carry a workspace id that the frames
/// themselves (plain `CGRect`s) cannot supply.
///
/// `stripFrame`/`railFrame` name the strip/rail's own on-screen region
/// directly. When nil, the region is the union of `tabFrames`/
/// `workspaceFrames`, which is `nil` itself for an empty list -- so an
/// explicit frame is what lets a strip or rail with zero items still
/// resolve a same-kind drag to insert index 0 inside its own area, instead
/// of that area going unrecognized entirely.
///
/// `stripViewport`/`railViewport` are the scroll views' visible frames. Item
/// frames are on screen but can lie outside them once the list scrolls, under
/// the readout or past an edge, so only a point inside the viewport may hit
/// an item as a thumbnail. An insert index counts hidden items too, but a
/// point beyond the viewport counts as at its edge: an item the user cannot
/// see must never be passed by a point sitting over the readout.
public struct DropSurfaces: Equatable, Sendable {
    public let canvas: CanvasGeometry
    public let stripWorkspace: WorkspaceID
    public let tabFrames: [TabItemFrame]
    public let workspaceFrames: [WorkspaceItemFrame]
    public let stripFrame: CGRect?
    public let railFrame: CGRect?
    public let stripViewport: CGRect?
    public let railViewport: CGRect?
    public let newTabZone: CGRect?
    public let newWorkspaceZone: CGRect?
    public let grid: GridDropSurfaces?

    public init(
        canvas: CanvasGeometry,
        stripWorkspace: WorkspaceID,
        tabFrames: [TabItemFrame],
        workspaceFrames: [WorkspaceItemFrame],
        stripFrame: CGRect? = nil,
        railFrame: CGRect? = nil,
        stripViewport: CGRect? = nil,
        railViewport: CGRect? = nil,
        newTabZone: CGRect?,
        newWorkspaceZone: CGRect?,
        grid: GridDropSurfaces? = nil
    ) {
        self.grid = grid
        self.canvas = canvas
        self.stripWorkspace = stripWorkspace
        self.tabFrames = tabFrames
        self.workspaceFrames = workspaceFrames
        self.stripFrame = stripFrame
        self.railFrame = railFrame
        self.stripViewport = stripViewport
        self.railViewport = railViewport
        self.newTabZone = newTabZone
        self.newWorkspaceZone = newWorkspaceZone
    }
}

/// The outer band of a pane frame, per side, that resolves to `.paneEdge`
/// instead of `.paneInterior`.
public let edgeBandFraction: CGFloat = 0.20

/// Resolves one drag frame's drop target from a point plus the surfaces it
/// could land on.
///
/// A shown grid answers alone (see `DropSurfaces`). Otherwise, precedence
/// when surfaces overlap on screen: the new-tab/new-workspace zones, then
/// the workspace rail, then the tab strip, then the canvas. Each
/// tier that contains the point owns the result outright, including `nil`
/// for a subject that tier does not accept -- the point never falls through
/// to a lower tier once a higher one contains it, since that would let (say)
/// a pane frame sitting under the rail leak a `.paneEdge` result.
///
/// Every pair this can return has a case in `GesturePlanner.plan`, and that is
/// a standing invariant, not a coincidence: a subject that reaches a surface
/// with no verb for it resolves to `nil` and springs back silently, which is
/// what a drop that means nothing should do. A target the planner cannot serve
/// would instead reach the user as a "Can't move there" rejection.
public func resolveDropTarget(at point: CGPoint, dragging: DragSubject, surfaces: DropSurfaces) -> DropTarget? {
    if let grid = surfaces.grid {
        return resolveGrid(at: point, dragging: dragging, grid: grid)
    }

    if let zone = resolveZone(at: point, dragging: dragging, surfaces: surfaces) {
        return zone
    }

    if let railBounds = surfaces.railFrame ?? unionRect(surfaces.workspaceFrames.map(\.frame)), railBounds.contains(point) {
        return resolveRail(at: point, dragging: dragging, surfaces: surfaces)
    }

    if let stripBounds = surfaces.stripFrame ?? unionRect(surfaces.tabFrames.map(\.frame)), stripBounds.contains(point) {
        return resolveStrip(at: point, dragging: dragging, surfaces: surfaces)
    }

    // The canvas is a pane's alone. Splitting or swapping is something only a
    // pane does to a pane, so a tab or a workspace over the canvas resolves to
    // nothing at all rather than to a target no plan can serve.
    if case .pane = dragging, let hit = surfaces.canvas.paneFrames.first(where: { $0.value.contains(point) }) {
        return resolveCanvas(at: point, paneID: hit.key, frame: hit.value)
    }

    return nil
}

/// The create-new zones, which only a pane may use: a pane is the only
/// subject `GesturePlanner` can carry into a tab or a workspace that does not
/// exist yet.
///
/// Every other subject falls THROUGH to the chrome the zone sits inside, where
/// the same free run means what that chrome means: past the last tab, a tab
/// takes the strip's end insertion index; below the last row, a workspace
/// takes the rail's. Scoping this here rather than by withholding the zone
/// keeps one zone rect serving every subject correctly.
private func resolveZone(at point: CGPoint, dragging: DragSubject, surfaces: DropSurfaces) -> DropTarget? {
    guard case .pane = dragging else { return nil }
    if let newTabZone = surfaces.newTabZone, newTabZone.contains(point) {
        return .newTab(surfaces.stripWorkspace)
    }
    if let newWorkspaceZone = surfaces.newWorkspaceZone, newWorkspaceZone.contains(point) {
        return .newWorkspace
    }
    return nil
}

/// Rearranging from inside the grid. A pane lands in the tab whose thumbnail
/// it is over, or in a new tab of whatever card it is over otherwise; a card's
/// tile takes no drop, and a dwell on a "+N" one uncovers the tabs it stands
/// for. A whole tab lands in the card it is over: another workspace's card
/// takes it as a migration, and its OWN card as a reorder among that card's
/// cells, which is the same target and the same verb the strip resolves for a
/// tab moved within its workspace. A workspace drag has nothing to land on
/// here.
///
/// A thumbnail is a whole-tab target with no edge bands: it is far too small
/// to divide into four zones, so nothing in the grid ever splits a pane.
private func resolveGrid(at point: CGPoint, dragging: DragSubject, grid: GridDropSurfaces) -> DropTarget? {
    guard grid.viewport.contains(point) else { return nil }
    func card() -> DropTarget? {
        grid.cards.first(where: { $0.frame.contains(point) }).map { .workspaceThumbnail($0.id) }
    }
    switch dragging {
    case .pane:
        if let hit = grid.thumbnails.first(where: { $0.frame.contains(point) }) {
            return .tabThumbnail(hit.id)
        }
        if let hit = grid.tiles.first(where: { $0.frame.contains(point) }) {
            return .moreTabs(hit.id)
        }
        return card()
    case .tab(let dragged):
        guard let hit = grid.cards.first(where: { $0.frame.contains(point) }) else { return nil }
        guard let card = grid.cardTabs.first(where: { $0.workspace == hit.id }),
              card.tabs.contains(where: { $0.id == dragged })
        else {
            return .workspaceThumbnail(hit.id)
        }
        return .tabStrip(
            workspace: hit.id, insertIndex: GridCardLayout.insertIndex(at: point, cells: card.tabs.map(\.frame))
        )
    case .workspace, .workspaces:
        return nil
    }
}

private func resolveRail(at point: CGPoint, dragging: DragSubject, surfaces: DropSurfaces) -> DropTarget? {
    switch dragging {
    case .pane, .tab:
        guard surfaces.railViewport?.contains(point) ?? true,
              let hit = surfaces.workspaceFrames.first(where: { $0.frame.contains(point) })
        else { return nil }
        return .workspaceThumbnail(hit.id)
    case .workspace, .workspaces:
        let centers = surfaces.workspaceFrames.map(\.frame.midY)
        let y = clamp(point.y, to: surfaces.railViewport.map { ($0.minY, $0.maxY) })
        return .workspaceRail(insertIndex: insertIndex(of: y, centers: centers))
    }
}

private func resolveStrip(at point: CGPoint, dragging: DragSubject, surfaces: DropSurfaces) -> DropTarget? {
    switch dragging {
    case .pane:
        guard surfaces.stripViewport?.contains(point) ?? true,
              let hit = surfaces.tabFrames.first(where: { $0.frame.contains(point) })
        else { return nil }
        return .tabThumbnail(hit.id)
    case .tab:
        let centers = surfaces.tabFrames.map(\.frame.midX)
        let x = clamp(point.x, to: surfaces.stripViewport.map { ($0.minX, $0.maxX) })
        return .tabStrip(workspace: surfaces.stripWorkspace, insertIndex: insertIndex(of: x, centers: centers))
    case .workspace, .workspaces:
        return nil
    }
}

private func resolveCanvas(at point: CGPoint, paneID: PaneID, frame: CGRect) -> DropTarget {
    guard let edge = edgeBand(at: point, in: frame) else { return .paneInterior(paneID) }
    return .paneEdge(paneID, edge)
}

/// The number of `centers` strictly left of (above, for the rail) `point`:
/// an item-center crossing rule, so a point over an item's own body still
/// lands in the gap on either side of it rather than "on" that item.
private func insertIndex(of point: CGFloat, centers: [CGFloat]) -> Int {
    centers.filter { $0 < point }.count
}

private func clamp(_ value: CGFloat, to range: (low: CGFloat, high: CGFloat)?) -> CGFloat {
    guard let range else { return value }
    return min(max(value, range.low), range.high)
}

private func unionRect(_ rects: [CGRect]) -> CGRect? {
    guard let first = rects.first else { return nil }
    return rects.dropFirst().reduce(first) { $0.union($1) }
}

/// The edge whose outer `edgeBandFraction` band contains `point`, or `nil`
/// for the inner 80% interior.
///
/// A corner sits inside two bands at once; the tie breaks on whichever band
/// the point is proportionally deeper into (distance to that edge divided by
/// that band's own depth), not on raw pixel distance, so a short axis and a
/// long axis stay comparable.
private func edgeBand(at point: CGPoint, in frame: CGRect) -> Edge? {
    let bandX = frame.width * edgeBandFraction
    let bandY = frame.height * edgeBandFraction

    var candidates: [(Edge, ratio: CGFloat)] = []
    let left = point.x - frame.minX
    let right = frame.maxX - point.x
    let top = point.y - frame.minY
    let bottom = frame.maxY - point.y

    if left <= bandX { candidates.append((.left, ratio(left, bandX))) }
    if right <= bandX { candidates.append((.right, ratio(right, bandX))) }
    if top <= bandY { candidates.append((.top, ratio(top, bandY))) }
    if bottom <= bandY { candidates.append((.bottom, ratio(bottom, bandY))) }

    return candidates.min(by: { $0.ratio < $1.ratio })?.0
}

private func ratio(_ distance: CGFloat, _ band: CGFloat) -> CGFloat {
    guard band > 0 else { return distance <= 0 ? 0 : .greatestFiniteMagnitude }
    return distance / band
}
