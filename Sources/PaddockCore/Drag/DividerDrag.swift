import CoreGraphics

/// Pure translation from a divider drag's pointer position to a clamped split
/// ratio, and back (ratio to boundary position) for painting the live
/// preview. Both directions share `region(for:)`: a `DividerHandle`'s own
/// `frame` only ever carries its CROSS-axis extent (`CanvasGeometry`'s
/// `dividerFrame` spans the full cross axis but only straddles the boundary
/// on the drag axis), so the along-axis extent a nested divider's ratio is
/// measured against is walked fresh from the canvas root down its own
/// `path`, bisecting at each ancestor's own boundary (`frame.midX`/`midY`) --
/// never at a ratio, which `DividerHandle` does not carry.
public enum DividerDragMath {
    public static let minRatio = 0.1
    public static let maxRatio = 0.9

    /// The full region `path` divides, in the same canvas-local space as
    /// `dividers`' own frames: `canvas` itself for the root (`path == []`,
    /// which spans the whole tab area), or a bisected descendant of it
    /// otherwise. An ancestor absent from `dividers` (a path that does not
    /// resolve) stops the walk early and returns whatever region had already
    /// been narrowed down.
    public static func region(for path: [Bool], tabID: TabID, dividers: [DividerHandle], canvas: CGRect) -> CGRect {
        var region = canvas
        for depth in 0..<path.count {
            let ancestorPath = Array(path.prefix(depth))
            guard let ancestor = dividers.first(where: { $0.tabID == tabID && $0.path == ancestorPath }) else {
                return region
            }
            let (first, second) = bisect(region, direction: ancestor.direction, boundary: boundary(of: ancestor))
            region = path[depth] ? second : first
        }
        return region
    }

    /// The ratio a pointer at `pointer` (canvas-local, matching `divider.frame`'s
    /// own space) represents, clamped to `minRatio...maxRatio`. Herdr's own
    /// per-pane size floor is enforced on its side; paddock never tries to
    /// duplicate it here, only this clamp.
    public static func ratio(atPointer pointer: CGPoint, divider: DividerHandle, dividers: [DividerHandle], canvas: CGRect) -> Double {
        let region = region(for: divider.path, tabID: divider.tabID, dividers: dividers, canvas: canvas)
        let raw: Double
        switch divider.direction {
        case .right:
            guard region.width > 0 else { return 0.5 }
            raw = Double((pointer.x - region.minX) / region.width)
        case .down:
            guard region.height > 0 else { return 0.5 }
            raw = Double((pointer.y - region.minY) / region.height)
        }
        return min(max(raw, minRatio), maxRatio)
    }

    /// The canvas-local coordinate `ratio` places `divider`'s own boundary
    /// at, for drawing the live line at the position release would commit.
    public static func boundary(forRatio ratio: Double, divider: DividerHandle, dividers: [DividerHandle], canvas: CGRect) -> CGFloat {
        let region = region(for: divider.path, tabID: divider.tabID, dividers: dividers, canvas: canvas)
        switch divider.direction {
        case .right: return region.minX + CGFloat(ratio) * region.width
        case .down: return region.minY + CGFloat(ratio) * region.height
        }
    }

    private static func boundary(of divider: DividerHandle) -> CGFloat {
        switch divider.direction {
        case .right: return divider.frame.midX
        case .down: return divider.frame.midY
        }
    }

    private static func bisect(_ region: CGRect, direction: SplitDirection, boundary: CGFloat) -> (first: CGRect, second: CGRect) {
        switch direction {
        case .right:
            let first = CGRect(x: region.minX, y: region.minY, width: boundary - region.minX, height: region.height)
            let second = CGRect(x: boundary, y: region.minY, width: region.maxX - boundary, height: region.height)
            return (first, second)
        case .down:
            let first = CGRect(x: region.minX, y: region.minY, width: region.width, height: boundary - region.minY)
            let second = CGRect(x: region.minX, y: boundary, width: region.width, height: region.maxY - boundary)
            return (first, second)
        }
    }
}

/// Pure state for one divider drag. The ratio is committed only on `ended()`,
/// never per frame -- matching the rule Herdglass's own `NSSplitView`
/// tracking loop keeps (`SplitContainerView.mouseDown`: published once the
/// tracking loop returns) -- and `cancelled()` never produces an op, mirroring
/// the pane-drag Esc contract `DragController.cancelled()` already keeps.
public struct DividerDragMachine: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        case dragging(divider: DividerHandle, startRatio: Double, liveRatio: Double)
    }

    /// Below this, a release is "the ratio never moved" -- finer than any
    /// real drag's resolution, so it only absorbs floating-point noise from
    /// re-deriving `startRatio` off the divider's own frame position.
    private static let unchangedTolerance = 0.0005

    public private(set) var phase: Phase = .idle

    public init() {}

    public var isDragging: Bool {
        guard case .dragging = phase else { return false }
        return true
    }

    public mutating func began(_ divider: DividerHandle, startRatio: Double) {
        phase = .dragging(divider: divider, startRatio: startRatio, liveRatio: startRatio)
    }

    public mutating func moved(to ratio: Double) {
        guard case let .dragging(divider, startRatio, _) = phase else { return }
        phase = .dragging(divider: divider, startRatio: startRatio, liveRatio: ratio)
    }

    /// Resolves the drag to idle and returns the single op to commit, or
    /// `nil` when nothing ever moved past `unchangedTolerance` -- a plain
    /// click-release on the gutter must issue no traffic at all.
    @discardableResult
    public mutating func ended() -> PrimitiveOp? {
        guard case let .dragging(divider, startRatio, liveRatio) = phase else { return nil }
        phase = .idle
        guard abs(liveRatio - startRatio) > Self.unchangedTolerance else { return nil }
        return .setSplitRatio(tab: divider.tabID, path: divider.path, ratio: liveRatio)
    }

    /// Esc: resolves to idle and issues no op, ever. The caller restores its
    /// own live preview to the returned `startRatio`.
    @discardableResult
    public mutating func cancelled() -> Double? {
        guard case let .dragging(_, startRatio, _) = phase else { return nil }
        phase = .idle
        return startRatio
    }
}
