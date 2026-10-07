import CoreGraphics
import Foundation

/// How much of a pane an Arrange mini pane draws, by the size of its box.
/// Each level adds to the one below it, so a box only ever gains lines as it
/// grows.
public enum TileDetail: Int, Comparable, Sendable {
    /// The status word and title, as a mini pane has always drawn.
    case status
    /// The pane's last lines.
    case tail
    /// A line above them: the harness, repo @ branch and age.
    case meta
    /// The status timeline under them.
    case timeline

    public static func < (lhs: TileDetail, rhs: TileDetail) -> Bool { lhs.rawValue < rhs.rawValue }

    public struct Thresholds: Equatable, Sendable {
        /// Three lines of the tail at its smallest size, about twenty
        /// columns wide: less is a smear, not output.
        public var tail = CGSize(width: 96, height: 40)
        /// Room for the meta line beside three lines of tail.
        public var meta = CGSize(width: 150, height: 72)
        /// Room for the timeline under the meta line and the tail.
        public var timeline = CGSize(width: 150, height: 110)

        public init() {}
    }

    public static func of(box: CGSize, thresholds: Thresholds = Thresholds()) -> TileDetail {
        func fits(_ minimum: CGSize) -> Bool { box.width >= minimum.width && box.height >= minimum.height }
        if fits(thresholds.timeline) { return .timeline }
        if fits(thresholds.meta) { return .meta }
        if fits(thresholds.tail) { return .tail }
        return .status
    }
}

/// How often Arrange re-reads the panes its tiles show. Every read is a
/// `pane.read` round trip to herdr, so the grid, which can show dozens of
/// panes, reads each one a third as often as a zoomed island, which shows a
/// handful at a size worth following.
public enum TileTailCadence {
    public static let grid: Duration = .seconds(3)
    public static let zoomed: Duration = .seconds(1)

    /// A pane's place in the cycle, so a canvas of tiles that appear together
    /// spreads its reads across the interval instead of sending them in one
    /// burst. Stable across launches: Swift's own hash is seeded per process.
    public static func offset(for pane: PaneID, interval: Duration) -> Duration {
        let milliseconds = max(1, interval.components.seconds * 1000 + interval.components.attoseconds / 1_000_000_000_000_000)
        let seed = pane.rawValue.unicodeScalars.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1.value) }
        return .milliseconds(Int64(seed % UInt64(milliseconds)))
    }

    /// The last `rows` of a tail that has `count`, as the range a tile draws.
    public static func shown(count: Int, fitting rows: Int) -> Range<Int> {
        let rows = max(0, min(rows, count))
        return (count - rows)..<count
    }
}
