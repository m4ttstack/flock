import Foundation

/// Turns AppKit wheel deltas into whole-cell scroll steps for the pane's own
/// program, the way libghostty's `Surface.scrollCallback` does for its own
/// mouse reports: precision deltas (trackpad points) accumulate until a full
/// cell has been crossed, emitting one step per cell and carrying the
/// remainder; discrete wheel notches are whole cells, with macOS's slow-click
/// 0.1 magnitude rounded out to one full notch. Without this a ~300pt swipe
/// would become one report per event (30-60 of them) instead of ~18.
///
/// Pure and value-typed so the whole table is testable; the view owns one per
/// surface and resets it when capture turns off so a momentum tail can never
/// emit after the app stopped listening.
public struct ScrollAccumulator: Equatable, Sendable {
    public private(set) var pendingX: Double = 0
    public private(set) var pendingY: Double = 0

    public init() {}

    public mutating func reset() {
        pendingX = 0
        pendingY = 0
    }

    /// Whole-cell steps to emit on each axis for one wheel event; the sign is
    /// the direction (positive y = scroll up, positive x = scroll left, the
    /// AppKit `scrollingDelta` convention).
    public mutating func add(
        deltaX: Double, deltaY: Double, precise: Bool, cellSize: MouseForwarding.CellSize
    ) -> (x: Int, y: Int) {
        let y: Int
        if deltaY == 0 {
            y = 0
        } else {
            let adjusted: Double
            if precise {
                adjusted = deltaY
            } else {
                let notches = deltaY > 0 ? max(deltaY, 1) : min(deltaY, -1)
                adjusted = notches * cellSize.height
            }
            (y, pendingY) = Self.step(pending: pendingY + adjusted, cell: cellSize.height)
        }

        let x: Int
        if deltaX == 0 {
            x = 0
        } else if !precise {
            x = Int(deltaX.rounded())
        } else {
            (x, pendingX) = Self.step(pending: pendingX + deltaX, cell: cellSize.width)
        }
        return (x, y)
    }

    private static func step(pending: Double, cell: Double) -> (Int, Double) {
        guard cell > 0, abs(pending) >= cell else { return (0, pending) }
        let steps = (pending / cell).rounded(.towardZero)
        return (Int(steps), pending - steps * cell)
    }
}
