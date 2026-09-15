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

    /// Panes are counted over the boxes the thumbnail draws, cached export
    /// included, so "pane 1" is the top-left box the user is looking at.
    public static func make(
        pane id: PaneID, model: SessionModel, exported: ExportedLayoutDescription?, homeDirectory: String
    ) -> PaneHoverCardContent? {
        guard let pane = model.panes[id] else { return nil }
        let tabLabel = model.tabs[pane.workspaceID]?.first { $0.tabID == pane.tabID }?.label ?? pane.tabID.rawValue
        let tabPanes = model.panes.values.filter { $0.tabID == pane.tabID }.map(\.paneID).sorted { $0.rawValue < $1.rawValue }
        let order = MiniPaneLayout.boxes(
            layout: model.layouts[pane.tabID], exported: exported, fallbackPanes: tabPanes,
            size: CGSize(width: 1000, height: 1000), padding: 0, gap: 0, displayScale: 1
        ).map(\.pane)
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

/// Where the hover card sits relative to the pointer.
public enum HoverCardPlacement {
    /// `offset` below and right of the pointer, flipped left or up past the
    /// pointer on whichever axis would leave `container`, and never outside
    /// it.
    public static func origin(pointer: CGPoint, card: CGSize, container: CGRect, offset: CGSize) -> CGPoint {
        var x = pointer.x + offset.width
        if x + card.width > container.maxX {
            x = pointer.x - offset.width - card.width
        }
        var y = pointer.y + offset.height
        if y + card.height > container.maxY {
            y = pointer.y - offset.height - card.height
        }
        return CGPoint(
            x: max(container.minX, min(x, container.maxX - card.width)),
            y: max(container.minY, min(y, container.maxY - card.height))
        )
    }
}
