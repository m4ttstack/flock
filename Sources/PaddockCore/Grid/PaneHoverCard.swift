import CoreGraphics

extension PaneRecord {
    /// What paddock calls a pane wherever it names one: the terminal's title,
    /// then herdr's label.
    public var displayTitle: String {
        [terminalTitleStripped, label].compactMap { $0 }.first { !$0.isEmpty } ?? "shell"
    }
}

/// Everything the grid's pane hover card says except the last output line,
/// which is fetched separately.
public struct PaneHoverCardContent: Equatable, Sendable {
    public let title: String
    public let status: AgentStatus
    /// The tab's label and the pane's place in it, "agents · pane 1 of 3".
    public let position: String
    public let cwd: String

    public var statusWord: String { status.rawValue }

    public init(title: String, status: AgentStatus, position: String, cwd: String) {
        self.title = title
        self.status = status
        self.position = position
        self.cwd = cwd
    }

    /// Panes are counted in the same reading order the thumbnail lays them
    /// out in, so "pane 1" is the top-left box the user is looking at.
    public static func make(pane id: PaneID, model: SessionModel, homeDirectory: String) -> PaneHoverCardContent? {
        guard let pane = model.panes[id] else { return nil }
        let tabLabel = model.tabs[pane.workspaceID]?.first { $0.tabID == pane.tabID }?.label ?? pane.tabID.rawValue
        let tabPanes = model.panes.values.filter { $0.tabID == pane.tabID }.map(\.paneID).sorted { $0.rawValue < $1.rawValue }
        let order = MiniPaneLayout.readingOrder(layout: model.layouts[pane.tabID], fallbackPanes: tabPanes)
        let position = order.firstIndex(of: id).map { "\(tabLabel) · pane \($0 + 1) of \(order.count)" } ?? tabLabel
        return PaneHoverCardContent(
            title: pane.displayTitle,
            status: pane.agentStatus,
            position: position,
            cwd: abbreviatingHome(pane.cwd, home: homeDirectory)
        )
    }

    static func abbreviatingHome(_ path: String, home: String) -> String {
        var home = home
        while home.count > 1, home.hasSuffix("/") {
            home.removeLast()
        }
        guard !home.isEmpty, home != "/" else { return path }
        if path == home { return "~" }
        guard path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }
}

/// Where the hover card sits relative to the pane it describes.
public enum HoverCardPlacement {
    /// Below the pane when the card fits there, above it otherwise, pinned to
    /// the pane's leading edge, and never outside `container`.
    public static func origin(anchor: CGRect, card: CGSize, container: CGRect, gap: CGFloat) -> CGPoint {
        let below = anchor.maxY + gap
        let above = anchor.minY - gap - card.height
        let y: CGFloat
        if below + card.height <= container.maxY {
            y = below
        } else if above >= container.minY {
            y = above
        } else {
            y = max(container.minY, container.maxY - card.height)
        }
        let x = max(container.minX, min(anchor.minX, container.maxX - card.width))
        return CGPoint(x: x, y: y)
    }
}
