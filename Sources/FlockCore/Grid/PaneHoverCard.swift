import CoreGraphics

extension PaneRecord {
    /// What flock calls a pane wherever it names one: the terminal's title,
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

/// Where the hover card sits: beside the pane it describes, never over it.
///
/// It followed the pointer until the pointer could never reach it. Anchoring
/// to the pane keeps both properties that bought: the card is outside the
/// pane's own box, so it cannot cover the title it is describing, and the box
/// is read live, so a scroll or an expanding card under a still pointer moves
/// the card with the pane rather than leaving it behind.
public enum HoverCardPlacement {
    /// `gap` to the trailing side of `pane`, flipped to the leading side when
    /// that would leave `container`, tops aligned, and never outside the
    /// container. A container too narrow to hold the card beside the pane on
    /// either side (under about 600pt, which the window's 900pt minimum rules
    /// out) keeps the card inside the grid at the cost of covering the pane.
    public static func origin(pane: CGRect, card: CGSize, container: CGRect, gap: CGFloat) -> CGPoint {
        let trailing = pane.maxX + gap
        let leading = pane.minX - gap - card.width
        var x = trailing
        if trailing + card.width > container.maxX {
            x = leading >= container.minX ? leading : widerSide(of: pane, in: container, trailing: trailing, leading: leading)
        }
        return CGPoint(
            x: max(container.minX, min(x, container.maxX - card.width)),
            y: max(container.minY, min(pane.minY, container.maxY - card.height))
        )
    }

    private static func widerSide(of pane: CGRect, in container: CGRect, trailing: CGFloat, leading: CGFloat) -> CGFloat {
        container.maxX - pane.maxX >= pane.minX - container.minX ? trailing : leading
    }
}
