import Foundation

/// The four directions a keyboard move aims a pane in, and the `Edge` of the
/// neighbor the pane lands against when it gets there: moving left puts the
/// pane on the left edge of whatever pane was to its left, which is what the
/// same drag would have done.
public enum PaneDirection: CaseIterable, Sendable {
    case left, right, up, down

    public var edge: Edge {
        switch self {
        case .left: .left
        case .right: .right
        case .up: .top
        case .down: .bottom
        }
    }
}

/// Which pane sits immediately beside another in a tab's own cell layout --
/// the pure half of the keyboard move commands, so what "the pane to the
/// left" means is decided here rather than inside a menu handler.
public enum PaneNeighbors {
    /// The nearest pane of `layout` on `direction`'s side of `pane`, or `nil`
    /// when nothing lies that way. A candidate qualifies only if it is
    /// strictly beyond `pane`'s own edge on that axis AND its span on the
    /// other axis overlaps `pane`'s, so a pane diagonally across the tab is
    /// never "to the left"; of those, the closest wins, and an exact tie on
    /// distance (two stacked panes sharing one column) is broken by the
    /// smaller offset on the other axis, which is the topmost or leftmost of
    /// them.
    public static func pane(_ pane: PaneID, toward direction: PaneDirection, in layout: LayoutSnapshot) -> PaneID? {
        guard let origin = layout.panes.first(where: { $0.paneID == pane })?.rect else { return nil }
        let candidates = layout.panes.filter { $0.paneID != pane && qualifies($0.rect, beside: origin, toward: direction) }
        return candidates.min { lhs, rhs in
            let left = (distance(from: origin, to: lhs.rect, toward: direction), crossOffset(lhs.rect, toward: direction))
            let right = (distance(from: origin, to: rhs.rect, toward: direction), crossOffset(rhs.rect, toward: direction))
            return left < right
        }?.paneID
    }

    /// The drop target a keyboard move compiles to, for the planner to turn
    /// into ops exactly as it does for the equivalent drag. `nil` when
    /// `direction` has no neighbor to land against.
    public static func moveTarget(for pane: PaneID, toward direction: PaneDirection, in layout: LayoutSnapshot) -> DropTarget? {
        self.pane(pane, toward: direction, in: layout).map { .paneEdge($0, direction.edge) }
    }

    /// The same neighbor read as a swap: a same-tab pane interior, which the
    /// planner turns into `pane.swap` rather than a move.
    public static func swapTarget(for pane: PaneID, toward direction: PaneDirection, in layout: LayoutSnapshot) -> DropTarget? {
        self.pane(pane, toward: direction, in: layout).map { .paneInterior($0) }
    }

    private static func qualifies(_ candidate: CellRect, beside origin: CellRect, toward direction: PaneDirection) -> Bool {
        switch direction {
        case .left:
            return candidate.x + candidate.width <= origin.x && overlapsVertically(candidate, origin)
        case .right:
            return candidate.x >= origin.x + origin.width && overlapsVertically(candidate, origin)
        case .up:
            return candidate.y + candidate.height <= origin.y && overlapsHorizontally(candidate, origin)
        case .down:
            return candidate.y >= origin.y + origin.height && overlapsHorizontally(candidate, origin)
        }
    }

    private static func distance(from origin: CellRect, to candidate: CellRect, toward direction: PaneDirection) -> Int {
        switch direction {
        case .left: origin.x - (candidate.x + candidate.width)
        case .right: candidate.x - (origin.x + origin.width)
        case .up: origin.y - (candidate.y + candidate.height)
        case .down: candidate.y - (origin.y + origin.height)
        }
    }

    private static func crossOffset(_ rect: CellRect, toward direction: PaneDirection) -> Int {
        switch direction {
        case .left, .right: rect.y
        case .up, .down: rect.x
        }
    }

    private static func overlapsVertically(_ lhs: CellRect, _ rhs: CellRect) -> Bool {
        lhs.y < rhs.y + rhs.height && rhs.y < lhs.y + lhs.height
    }

    private static func overlapsHorizontally(_ lhs: CellRect, _ rhs: CellRect) -> Bool {
        lhs.x < rhs.x + rhs.width && rhs.x < lhs.x + lhs.width
    }
}
