import CoreGraphics

/// Arrange's layout: islands packed left to right in rail order, every
/// thumbnail one size, the largest size at which the whole view fits.
public enum IslandLayout {
    public struct Metrics: Equatable, Sendable {
        /// Between islands, across a row and down the view.
        public var islandGap: CGFloat = 28
        public var tabGap: CGFloat = 8
        public var horizontalPadding: CGFloat = 16
        /// Top padding, the header row and the gap under it.
        public var headerHeight: CGFloat = 46
        public var bottomPadding: CGFloat = 16
        public var aspect: CGFloat = 0.55
        public var minimumWidth: CGFloat = 120
        public var maximumWidth: CGFloat = 200
        public var step: CGFloat = 2
        /// The dormant strip and the gap above it.
        public var dormantStripHeight: CGFloat = 44

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

        /// `islands` laid out below this fit's rows at its own thumbnail
        /// size, every island already drawn left where it is: the shape a
        /// dormant island sprung open by a live drag takes.
        public func appending(_ islands: [Island], width: CGFloat, metrics: Metrics = Metrics()) -> Fit {
            guard !islands.isEmpty else { return self }
            let added = IslandLayout.layout(islands, thumbnail: thumbnailWidth, in: width, metrics: metrics)
            return Fit(
                thumbnailWidth: thumbnailWidth, thumbnailHeight: thumbnailHeight, rows: rows + added.rows,
                tabsPerRow: tabsPerRow.merging(added.perRow) { _, new in new }, scrolls: true
            )
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

    static func layout(_ islands: [Island], thumbnail: CGFloat, in width: CGFloat, metrics: Metrics)
        -> (rows: [[WorkspaceID]], perRow: [WorkspaceID: Int], height: CGFloat)
    {
        let maxAcross = max(1, Int((width - 2 * metrics.horizontalPadding + metrics.tabGap) / (thumbnail + metrics.tabGap)))
        var rows: [[WorkspaceID]] = []
        var perRow: [WorkspaceID: Int] = [:]
        var rowHeights: [CGFloat] = []
        var x: CGFloat = 0
        for island in islands {
            let across = min(max(1, island.tabs), maxAcross)
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

    public static func fit(_ islands: [Island], in size: CGSize, hasDormantStrip: Bool, metrics: Metrics = Metrics()) -> Fit {
        let available = size.height - (hasDormantStrip ? metrics.dormantStripHeight : 0)
        var width = metrics.maximumWidth
        while width >= metrics.minimumWidth {
            let candidate = layout(islands, thumbnail: width, in: size.width, metrics: metrics)
            if candidate.height <= available {
                return Fit(
                    thumbnailWidth: width, thumbnailHeight: thumbnailHeight(width, metrics: metrics),
                    rows: candidate.rows, tabsPerRow: candidate.perRow, scrolls: false
                )
            }
            width -= metrics.step
        }
        let floor = layout(islands, thumbnail: metrics.minimumWidth, in: size.width, metrics: metrics)
        return Fit(
            thumbnailWidth: metrics.minimumWidth, thumbnailHeight: thumbnailHeight(metrics.minimumWidth, metrics: metrics),
            rows: floor.rows, tabsPerRow: floor.perRow, scrolls: true
        )
    }
}

/// The fit Arrange draws with. A drag freezes it: a drop target that moved
/// under the pointer would land the drop somewhere nobody aimed.
public struct IslandFitHold: Equatable, Sendable {
    public private(set) var fit: IslandLayout.Fit?

    public init() {}

    public mutating func update(
        _ islands: [IslandLayout.Island], in size: CGSize, hasDormantStrip: Bool, dragging: Bool,
        metrics: IslandLayout.Metrics = IslandLayout.Metrics()
    ) -> IslandLayout.Fit {
        if dragging, let fit { return fit }
        let next = IslandLayout.fit(islands, in: size, hasDormantStrip: hasDormantStrip, metrics: metrics)
        fit = next
        return next
    }
}
