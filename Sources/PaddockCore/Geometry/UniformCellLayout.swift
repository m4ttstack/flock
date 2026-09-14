import CoreGraphics

/// What one pane box holds besides its terminal surface, in points: the
/// divider gutter, the legend band, the border and the content insets. The
/// same for every pane, whatever its cell size.
public struct PaneChrome: Equatable, Sendable {
    public var horizontal: CGFloat
    public var vertical: CGFloat

    public init(horizontal: CGFloat, vertical: CGFloat) {
        self.horizontal = horizontal
        self.vertical = vertical
    }
}

/// Where herdr's cell grid sits on the canvas: one uniform box cell, and the
/// origin the letterboxed grid starts at.
public struct CanvasGrid: Equatable, Sendable {
    public let origin: CGPoint
    public let cell: CGSize

    public init(origin: CGPoint, cell: CGSize) {
        self.origin = origin
        self.cell = cell
    }

    /// `rect` (in herdr cells, relative to `area`) as a canvas frame.
    public func frame(for rect: CellRect, area: CellRect) -> CGRect {
        CGRect(
            x: origin.x + CGFloat(rect.x - area.x) * cell.width,
            y: origin.y + CGFloat(rect.y - area.y) * cell.height,
            width: CGFloat(rect.width) * cell.width,
            height: CGFloat(rect.height) * cell.height
        )
    }
}

/// The result of fitting herdr's grid into a canvas at one shared font size.
///
/// Two cell sizes coexist: `surfaceCell` is the terminal cell the font
/// actually renders at `fontSize` (every pane's surface is exactly its
/// cols x rows of these), and `boxCell` is the larger canvas cell each pane
/// BOX is laid out on, which is `surfaceCell` plus the chrome share of the
/// smallest pane so that every box can hold its surface plus chrome.
public struct UniformCellFit: Equatable, Sendable {
    public let fontSize: Double
    public let surfaceCell: CGSize
    public let boxCell: CGSize
    public let origin: CGPoint

    public var grid: CanvasGrid { CanvasGrid(origin: origin, cell: boxCell) }

    public func boxFrame(for rect: CellRect, area: CellRect) -> CGRect {
        grid.frame(for: rect, area: area)
    }

    public func surfaceSize(cols: Int, rows: Int) -> CGSize {
        CGSize(width: CGFloat(cols) * surfaceCell.width, height: CGFloat(rows) * surfaceCell.height)
    }
}

public enum UniformCellLayout {
    /// The floor the fit stops shrinking at; below this the grid overflows
    /// the canvas rather than the text becoming unreadable.
    public static let minimumFontSize: Double = 6
    public static let fontSizeStep: Double = 0.5

    /// Picks the largest font size, stepping down from `maxFontSize` in half
    /// points, at which `area` cells of `boxCell` fit inside `canvas`, where
    /// `boxCell = cellMetrics(size) + chrome / smallestPane` per axis. The
    /// grid is centered in the canvas; a grid that cannot fit even at
    /// `minimumFontSize` is placed at the canvas origin and overflows.
    ///
    /// `cellMetrics` returns the terminal cell in points for a font size; it
    /// is injected because measuring a font needs CoreText, which the caller
    /// owns.
    public static func fit(
        area: CellRect,
        panes: [CellRect],
        canvas: CGSize,
        chrome: PaneChrome,
        maxFontSize: Double,
        cellMetrics: (Double) -> CGSize
    ) -> UniformCellFit {
        guard area.width > 0, area.height > 0 else {
            return UniformCellFit(fontSize: maxFontSize, surfaceCell: .zero, boxCell: .zero, origin: .zero)
        }
        let narrowest = max(1, panes.map(\.width).filter { $0 > 0 }.min() ?? area.width)
        let shortest = max(1, panes.map(\.height).filter { $0 > 0 }.min() ?? area.height)
        let chromeShare = CGSize(
            width: chrome.horizontal / CGFloat(narrowest),
            height: chrome.vertical / CGFloat(shortest)
        )

        func candidate(_ fontSize: Double) -> (fit: UniformCellFit, gridSize: CGSize) {
            let surfaceCell = cellMetrics(fontSize)
            let boxCell = CGSize(width: surfaceCell.width + chromeShare.width, height: surfaceCell.height + chromeShare.height)
            let gridSize = CGSize(width: CGFloat(area.width) * boxCell.width, height: CGFloat(area.height) * boxCell.height)
            let origin = CGPoint(
                x: max(0, (canvas.width - gridSize.width) / 2),
                y: max(0, (canvas.height - gridSize.height) / 2)
            )
            return (UniformCellFit(fontSize: fontSize, surfaceCell: surfaceCell, boxCell: boxCell, origin: origin), gridSize)
        }

        var fontSize = max(minimumFontSize, maxFontSize)
        while fontSize >= minimumFontSize {
            let (fit, gridSize) = candidate(fontSize)
            if gridSize.width <= canvas.width && gridSize.height <= canvas.height {
                return fit
            }
            fontSize -= fontSizeStep
        }
        return candidate(minimumFontSize).fit
    }
}
