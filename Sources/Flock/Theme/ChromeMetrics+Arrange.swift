import FlockCore
import SwiftUI

extension ChromeMetrics.Grid {
    /// A mini pane's status edge: its leading side in the status hue.
    static let statusEdgeWidth: CGFloat = 2
    /// The faint coat of its hue a done or blocked mini pane's body takes,
    /// enough to find it across the canvas without competing with its text.
    static let statusWashOpacity: Double = 0.10

    /// Inside a mini pane that draws its tail: clear of the status edge on
    /// the leading side, and tighter than the status layout's padding so a
    /// small box spends its height on lines.
    static let tileLeadingPadding: CGFloat = 8
    static let tileTrailingPadding: CGFloat = 6
    static let tileVerticalPadding: CGFloat = 5
    static let tileRowSpacing: CGFloat = 4
    static let tileMetaSpacing: CGFloat = 6
    static let tileTimelineHeight: CGFloat = 3
    /// The tail's type is fitted to the box's width between these. The floor
    /// still reads as text on a Retina display; the ceiling keeps a
    /// zoomed tile's output at about the terminal's own size.
    static let tileTailMinSize: CGFloat = 5.5
    static let tileTailMaxSize: CGFloat = 9.5
    static let zoomedTileTailMaxSize: CGFloat = 11.5
}

extension ChromeMetrics.Grid {
    static let zoomDuration: Double = 0.3
    static let zoomCrossfadeDuration: Double = 0.2
    /// How far the grid draws back behind an island zooming out of it.
    static let zoomRecedeScale: CGFloat = 0.96
    /// The island header's zoom and close controls: no taller than the
    /// header row they sit in.
    static let zoomControlSize: CGFloat = 20
    static let zoomControlHorizontalPadding: CGFloat = 5
    static let zoomControlSpacing: CGFloat = 5
}

extension ChromeType {
    static let arrangeZoomKey = mono(10)
    static let arrangeZoomSymbol = Font.system(size: 10, weight: .semibold)
    static let arrangeTileMeta = mono(9)
    static let arrangeTileMetaZoomed = mono(10.5)
}
