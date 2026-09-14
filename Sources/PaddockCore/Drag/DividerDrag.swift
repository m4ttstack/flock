import CoreGraphics

/// Pure translation from a divider drag's pointer position to a clamped split
/// ratio, and back (ratio to boundary position) for painting the live
/// preview. Both read `divider.regionFrame` directly rather than
/// reconstructing it from ancestor frames: `regionFrame` is the exact rect
/// `CanvasGeometry` itself bisected to place `frame`'s own boundary (cell
/// rounding included), so a value read from it can never drift from wherever
/// the two children actually render.
public enum DividerDragMath {
    public static let minRatio = 0.1
    public static let maxRatio = 0.9

    /// The ratio a pointer at `pointer` (canvas-local, matching
    /// `divider.regionFrame`'s own space) represents, clamped to the
    /// tighter of `minRatio...maxRatio` and whatever keeps both children at
    /// or above herdr's per-pane cell floor (see `clamped(_:divider:)`).
    public static func ratio(atPointer pointer: CGPoint, divider: DividerHandle) -> Double {
        clamped(rawRatio(atPointer: pointer, divider: divider), divider: divider)
    }

    /// The same translation, unclamped -- for sampling a divider's CURRENT
    /// position (`DividerDragMachine.began`'s own `startRatio`), which may
    /// already sit below whatever floor a later commit would enforce (herdr
    /// itself never enforced one; only paddock's own clamp does, and only on
    /// what it commits). Running the START sample through the full clamp
    /// would snap the panes to the floor on a bare press, before the user
    /// has moved anything at all. Every ratio this drag actually COMMITS
    /// still goes through `ratio(atPointer:)`'s full clamp.
    public static func rawRatio(atPointer pointer: CGPoint, divider: DividerHandle) -> Double {
        let region = divider.regionFrame
        switch divider.direction {
        case .right:
            guard region.width > 0 else { return 0.5 }
            return Double((pointer.x - region.minX) / region.width)
        case .down:
            guard region.height > 0 else { return 0.5 }
            return Double((pointer.y - region.minY) / region.height)
        }
    }

    /// The canvas-local coordinate `ratio` places `divider`'s own boundary
    /// at, for drawing the live line at the position release would commit.
    public static func boundary(forRatio ratio: Double, divider: DividerHandle) -> CGFloat {
        let region = divider.regionFrame
        switch divider.direction {
        case .right: return region.minX + CGFloat(ratio) * region.width
        case .down: return region.minY + CGFloat(ratio) * region.height
        }
    }

    /// herdr's `set_ratio_at` clamps only the ratio itself, to
    /// `minRatio...maxRatio`; the 4-column/2-row per-pane floor lives inside
    /// `resize`, which silently ENLARGES an undersized pane rather than
    /// rejecting the ratio that produced it -- exactly the surface/pane
    /// desync `SurfaceGrid` warns about. Paddock clamps in cells too, to
    /// whichever bound is tighter, so a drag can never ask for a child
    /// smaller than herdr will actually give it. A region too small to seat
    /// both floors at once (fewer than twice the floor's own cell count)
    /// falls back to the plain ratio clamp -- there is no honest answer to
    /// give, and herdr's own enlargement is what will actually happen
    /// either way.
    private static func clamped(_ raw: Double, divider: DividerHandle) -> Double {
        guard divider.cellExtent > 0 else { return min(max(raw, minRatio), maxRatio) }
        let floorFraction = Double(floorCells(for: divider.direction)) / Double(divider.cellExtent)
        let lower = max(minRatio, floorFraction)
        let upper = min(maxRatio, 1 - floorFraction)
        guard lower <= upper else { return min(max(raw, minRatio), maxRatio) }
        return min(max(raw, lower), upper)
    }

    private static func floorCells(for direction: SplitDirection) -> Int {
        switch direction {
        case .right: return 4
        case .down: return 2
        }
    }
}

/// Pure state for one divider drag, composing `DragGestureMachine`
/// (PaddockCore) for the arm/release latch rather than reimplementing it: a
/// second `.begin` while `.cancelledAwaitingRelease` must stay a no-op, which
/// is exactly the property `DragGestureMachine` already carries for the pane
/// drags. This struct adds only what a divider needs on top -- the dragged
/// handle itself and its start/live ratio -- since `DragGestureMachine` on
/// its own carries no payload.
///
/// The ratio is committed only on `ended()`, never per frame -- matching the
/// rule Herdglass's own `NSSplitView` tracking loop keeps
/// (`SplitContainerView.mouseDown`: published once the tracking loop
/// returns) -- and `cancelled()` never produces an op, mirroring the
/// pane-drag Esc contract `DragController.cancelled()` already keeps.
public struct DividerDragMachine: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        case dragging(divider: DividerHandle, startRatio: Double, liveRatio: Double)
        /// Esc landed; the button is still down. `moved()` and a further
        /// `began()` are both no-ops until `ended()` sees the release.
        case cancelledAwaitingRelease
    }

    private struct Payload: Equatable, Sendable {
        let divider: DividerHandle
        let startRatio: Double
        var liveRatio: Double
    }

    /// Below this, a release is "the ratio never moved" -- finer than any
    /// real drag's resolution, so it only absorbs floating-point noise.
    private static let unchangedTolerance = 0.0005

    private var gesture = DragGestureMachine()
    private var payload: Payload?

    public init() {}

    public var phase: Phase {
        switch gesture.state {
        case .idle:
            return .idle
        case .live:
            guard let payload else { return .idle }
            return .dragging(divider: payload.divider, startRatio: payload.startRatio, liveRatio: payload.liveRatio)
        case .cancelledAwaitingRelease:
            return .cancelledAwaitingRelease
        }
    }

    public var isDragging: Bool { gesture.state == .live }

    /// `startRatio` is derived from `divider`'s OWN current boundary
    /// (`DividerDragMath.rawRatio` at its frame's own midpoint), never from
    /// wherever the press happened to land inside the gutter -- the two can
    /// differ by up to half the hit zone's width, which would otherwise
    /// make a one-point nudge issue no op at all (start already equals the
    /// first live sample) or an out-and-back drag issue a redundant one.
    /// Unclamped: the divider's CURRENT position may already sit below
    /// whatever floor a commit would enforce (nothing enforced one before
    /// now), and running it through the full clamp would jump the panes on
    /// a bare press, before any real movement. Returns whether the begin
    /// actually took effect (refused while `.cancelledAwaitingRelease` or
    /// already dragging).
    @discardableResult
    public mutating func began(_ divider: DividerHandle) -> Bool {
        guard gesture.handle(.begin) == .start else { return false }
        let start = DividerDragMath.rawRatio(atPointer: CGPoint(x: divider.frame.midX, y: divider.frame.midY), divider: divider)
        payload = Payload(divider: divider, startRatio: start, liveRatio: start)
        return true
    }

    public mutating func moved(to pointer: CGPoint) {
        guard gesture.tracksMotion, let divider = payload?.divider else { return }
        payload?.liveRatio = DividerDragMath.ratio(atPointer: pointer, divider: divider)
    }

    /// Resolves the drag to idle and returns the single op to commit, or
    /// `nil` when nothing ever moved past `unchangedTolerance`, or the
    /// gesture was cancelled -- a plain click-release on the gutter, and a
    /// release after Esc, must both issue no traffic at all.
    @discardableResult
    public mutating func ended() -> PrimitiveOp? {
        let accepted = gesture.handle(.release) == .end
        let finished = payload
        payload = nil
        guard accepted, let finished else { return nil }
        guard abs(finished.liveRatio - finished.startRatio) > Self.unchangedTolerance else { return nil }
        return .setSplitRatio(tab: finished.divider.tabID, path: finished.divider.path, ratio: finished.liveRatio)
    }

    /// Esc: latches into `.cancelledAwaitingRelease` and issues no op, ever.
    /// The caller restores its own live preview to the returned
    /// `startRatio`; `payload` itself is kept (not cleared) so a stray
    /// `moved()` before the release still has a divider to ignore, but
    /// `gesture.tracksMotion` is already false, so it has no effect.
    @discardableResult
    public mutating func cancelled() -> Double? {
        guard gesture.handle(.cancel) == .cancel else { return nil }
        return payload?.startRatio
    }

    /// The app resigned active with the button still down: no release is
    /// ever coming. Ends the gesture outright, issuing no op.
    public mutating func abandoned() {
        _ = gesture.handle(.abandon)
        payload = nil
    }
}
