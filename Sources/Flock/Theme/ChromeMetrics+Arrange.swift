import FlockCore
import SwiftUI

extension ChromeMetrics.Grid {
    /// The faint coat of its hue a done or blocked mini pane's body takes,
    /// enough to find it across the canvas without competing with its text.
    static let statusWashOpacity: Double = 0.10

    /// A thumbnail part's state, washed over its whole face: hover takes the
    /// chrome's one hover wash (`HoverWash.opacity`), a press a stronger coat
    /// of the same, and the active part a coat of accent under either.
    static let pressWashOpacity: Double = 0.16
    static let activeWashOpacity: Double = 0.16

    /// Inside a mini pane that draws its tail: tighter than the status
    /// layout's padding, so a small box spends its height on lines.
    static let tileLeadingPadding: CGFloat = 8
    static let tileTrailingPadding: CGFloat = 6
    static let tileVerticalPadding: CGFloat = 5
    static let tileRowSpacing: CGFloat = 4
    static let tileMetaSpacing: CGFloat = 6
    /// The tail's type is fitted to the box's width between these. The floor
    /// still reads as text on a Retina display; the ceiling keeps a
    /// zoomed tile's output at about the terminal's own size.
    static let tileTailMinSize: CGFloat = 5.5
    static let tileTailMaxSize: CGFloat = 9.5
    static let zoomedTileTailMaxSize: CGFloat = 11.5
    static let chatPillInset: CGFloat = 5
}

extension ChromeMetrics.Grid {
    static let zoomDuration: Double = 0.3
    static let zoomCrossfadeDuration: Double = 0.2
    /// How far the grid draws back behind an island zooming out of it.
    static let zoomRecedeScale: CGFloat = 0.96
    /// The island header's zoom and close controls: no taller than the
    /// header row they sit in.
    static let zoomControlSize: CGFloat = 24
    static let zoomControlHorizontalPadding: CGFloat = 9
    static let zoomControlSpacing: CGFloat = 5
}

extension ChromeType {
    static let arrangeZoomKey = mono(10.5)
    static let arrangeZoomLabel = inter(12, .medium)
    static let arrangeZoomSymbol = Font.system(size: 12, weight: .semibold)
    static let arrangeTileMeta = mono(9)
    static let arrangeTileMetaZoomed = mono(10.5)
}
