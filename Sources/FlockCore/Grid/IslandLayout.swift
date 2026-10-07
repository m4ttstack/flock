import CoreGraphics

/// Arrange's layout: islands packed left to right in rail order, every
/// thumbnail one size, the largest size at which the whole view fits. An
/// island may wrap its tabs onto more rows when that lets every thumbnail
/// grow.
public enum IslandLayout {
    public struct Metrics: Equatable, Sendable {
        /// Between islands, across a row and down the view.
        public var islandGap: CGFloat = 28
        public var tabGap: CGFloat = 8
        public var horizontalPadding: CGFloat = 16
        /// Top padding, the header row and the gap under it.
        public var headerHeight: CGFloat = 46
        public var bottomPadding: CGFloat = 16
        public var aspect: CGFloat = 0.62
        public var minimumWidth: CGFloat = 120
        /// About 80 columns of the terminal face at 9pt, which is where a
        /// one-pane tile reads its pane's whole tail. Past it a thumbnail
        /// only grows its type, so a window holding one small workspace
        /// leaves the canvas empty rather than drawing a poster.
        public var maximumWidth: CGFloat = 440
        public var step: CGFloat = 2

        public init() {}
    }

    public struct Island: Equatable, Sendable {
        public let id: WorkspaceID
        public let tabs: Int

        public init(id: WorkspaceID, tabs: Int) {
            self.id = id
            self.tabs = tabs
        }
    }

    public struct Fit: Equatable, Sendable {
        public let thumbnailWidth: CGFloat
        public let thumbnailHeight: CGFloat
        public let rows: [[WorkspaceID]]
        public let tabsPerRow: [WorkspaceID: Int]
        public let scrolls: Bool

        public init(
            thumbnailWidth: CGFloat, thumbnailHeight: CGFloat, rows: [[WorkspaceID]], tabsPerRow: [WorkspaceID: Int], scrolls: Bool
        ) {
            self.thumbnailWidth = thumbnailWidth
            self.thumbnailHeight = thumbnailHeight
            self.rows = rows
            self.tabsPerRow = tabsPerRow
            self.scrolls = scrolls
        }
    }

    public static func thumbnailHeight(_ width: CGFloat, metrics: Metrics) -> CGFloat {
        (width * metrics.aspect).rounded()
    }

    public static func width(tabs: Int, perRow: Int, thumbnail: CGFloat, metrics: Metrics) -> CGFloat {
        let across = CGFloat(max(1, min(tabs, perRow)))
        return 2 * metrics.horizontalPadding + across * thumbnail + (across - 1) * metrics.tabGap
    }

    static func height(tabs: Int, perRow: Int, thumbnail: CGFloat, metrics: Metrics) -> CGFloat {
        let rows = CGFloat((max(1, tabs) + perRow - 1) / perRow)
        return metrics.headerHeight + rows * thumbnailHeight(thumbnail, metrics: metrics)
            + (rows - 1) * metrics.tabGap + metrics.bottomPadding
    }

    /// `columns` caps every island's tabs per row.
    static func layout(_ islands: [Island], thumbnail: CGFloat, in width: CGFloat, columns: Int = .max, metrics: Metrics)
        -> (rows: [[WorkspaceID]], perRow: [WorkspaceID: Int], height: CGFloat)
    {
        let maxAcross = max(1, Int((width - 2 * metrics.horizontalPadding + metrics.tabGap) / (thumbnail + metrics.tabGap)))
        var rows: [[WorkspaceID]] = []
        var perRow: [WorkspaceID: Int] = [:]
        var rowHeights: [CGFloat] = []
        var x: CGFloat = 0
        for island in islands {
            let across = balancedAcross(tabs: island.tabs, cap: min(columns, maxAcross))
            perRow[island.id] = across
            let w = self.width(tabs: island.tabs, perRow: across, thumbnail: thumbnail, metrics: metrics)
            let h = height(tabs: island.tabs, perRow: across, thumbnail: thumbnail, metrics: metrics)
            if rows.isEmpty || x + metrics.islandGap + w > width {
                rows.append([island.id])
                rowHeights.append(h)
                x = w
            } else {
                rows[rows.count - 1].append(island.id)
                rowHeights[rowHeights.count - 1] = max(rowHeights[rowHeights.count - 1], h)
                x += metrics.islandGap + w
            }
        }
        let total = rowHeights.reduce(0, +) + CGFloat(max(0, rowHeights.count - 1)) * metrics.islandGap
        return (rows, perRow, total)
    }

    /// Tabs per row for `tabs` tabs at most `cap` across, spread over the
    /// fewest rows the cap allows as evenly as they go: five under a cap of
    /// three or four are three over two, never four over one.
    public static func balancedAcross(tabs: Int, cap: Int) -> Int {
        let tabs = max(1, tabs), cap = max(1, cap)
        let rows = (tabs + cap - 1) / cap
        return (tabs + rows - 1) / rows
    }

    /// The column caps worth trying, widest first: each wraps some island
    /// further than the cap before it.
    static func columnCaps(_ islands: [Island]) -> [Int] {
        let widest = islands.map { max(1, $0.tabs) }.max() ?? 1
        var seen: [[Int]] = []
        var caps: [Int] = []
        for cap in stride(from: widest, through: 1, by: -1) {
            let shape = islands.map { balancedAcross(tabs: $0.tabs, cap: cap) }
            if !seen.contains(shape) {
                seen.append(shape)
                caps.append(cap)
            }
        }
        return caps
    }

    /// The largest thumbnail at which every island fits `size`. At each size
    /// the unwrapped layout is tried first, so an island wraps its tabs only
    /// when that is what lets the thumbnails grow, never to look tidier at
    /// the same size.
    public static func fit(_ islands: [Island], in size: CGSize, metrics: Metrics = Metrics()) -> Fit {
        let caps = columnCaps(islands)
        var width = metrics.maximumWidth
        while width >= metrics.minimumWidth {
            for cap in caps {
                let candidate = layout(islands, thumbnail: width, in: size.width, columns: cap, metrics: metrics)
                if candidate.height <= size.height {
                    return Fit(
                        thumbnailWidth: width, thumbnailHeight: thumbnailHeight(width, metrics: metrics),
                        rows: candidate.rows, tabsPerRow: candidate.perRow, scrolls: false
                    )
                }
            }
            width -= metrics.step
        }
        let floor = layout(islands, thumbnail: metrics.minimumWidth, in: size.width, metrics: metrics)
        return Fit(
            thumbnailWidth: metrics.minimumWidth, thumbnailHeight: thumbnailHeight(metrics.minimumWidth, metrics: metrics),
            rows: floor.rows, tabsPerRow: floor.perRow, scrolls: true
        )
    }

    /// One island filling `size` exactly, its thumbnails stretched to the
    /// canvas rather than held to the grid's aspect: a zoomed island is read,
    /// so its tiles take every point the window has. The column count is the
    /// one whose tiles hold the largest box between `minimumAspect` and
    /// `maximumAspect` (height over width), so two tabs sit side by side as
    /// two tall panes rather than as two strips.
    public static func zoomFit(
        _ island: Island, in size: CGSize, metrics: Metrics = Metrics(),
        minimumAspect: CGFloat = 0.45, maximumAspect: CGFloat = 1.4
    ) -> Fit {
        let tabs = max(1, island.tabs)
        var best: (score: CGFloat, across: Int, width: CGFloat, height: CGFloat)?
        for across in 1...tabs where balancedAcross(tabs: tabs, cap: across) == across {
            let rows = (tabs + across - 1) / across
            let width = ((size.width - 2 * metrics.horizontalPadding - CGFloat(across - 1) * metrics.tabGap) / CGFloat(across))
                .rounded(.down)
            let height = ((size.height - metrics.headerHeight - metrics.bottomPadding - CGFloat(rows - 1) * metrics.tabGap)
                / CGFloat(rows)).rounded(.down)
            guard width > 0, height > 0 else { continue }
            let score = min(width, height / minimumAspect) * min(height, width * maximumAspect)
            if best.map({ score > $0.score }) ?? true { best = (score, across, width, height) }
        }
        let floorHeight = thumbnailHeight(metrics.minimumWidth, metrics: metrics)
        let across = best?.across ?? 1
        let width = max(metrics.minimumWidth, best?.width ?? 0)
        let height = max(floorHeight, best?.height ?? 0)
        return Fit(
            thumbnailWidth: width, thumbnailHeight: height, rows: [[island.id]], tabsPerRow: [island.id: across],
            scrolls: width > (best?.width ?? 0) || height > (best?.height ?? 0)
        )
    }
}

/// The fit Arrange draws with. A drag freezes it: a drop target that moved
/// under the pointer would land the drop somewhere nobody aimed.
public struct IslandFitHold: Equatable, Sendable {
    public private(set) var fit: IslandLayout.Fit?

    public init() {}

    public mutating func update(
        _ islands: [IslandLayout.Island], in size: CGSize, dragging: Bool,
        metrics: IslandLayout.Metrics = IslandLayout.Metrics()
    ) -> IslandLayout.Fit {
        if dragging, let fit { return fit }
        let next = IslandLayout.fit(islands, in: size, metrics: metrics)
        fit = next
        return next
    }

    /// The zoomed island's fit, frozen by a drag the same way.
    public mutating func update(
        zoomed island: IslandLayout.Island, in size: CGSize, dragging: Bool,
        metrics: IslandLayout.Metrics = IslandLayout.Metrics()
    ) -> IslandLayout.Fit {
        if dragging, let fit, fit.rows == [[island.id]] { return fit }
        let next = IslandLayout.zoomFit(island, in: size, metrics: metrics)
        fit = next
        return next
    }
}
