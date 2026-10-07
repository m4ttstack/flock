import Foundation

/// What a Claude Code pane sitting at its prompt is still running behind it:
/// background shells, monitors, a subagent. herdr reports such a pane idle or
/// done, so flock reads it off the footer Claude Code draws under its prompt
/// box, e.g. `⏵⏵ auto mode on · 1 shell · ← for agents`.
public enum BackgroundWork {
    /// How often an eligible pane's screen is read.
    public static let readInterval: Duration = .seconds(10)

    /// Only a Claude Code pane between turns has a footer worth reading: a
    /// working or blocked pane already says what it is doing.
    public static func isEligible(_ pane: PaneRecord) -> Bool {
        pane.agent == ChatButtonModel.claudeAgent && (pane.agentStatus == .idle || pane.agentStatus == .done)
    }

    /// The footer's own words for the work, `1 shell` or `1 shell, 1 monitor`,
    /// or `1 subagent` from the agents panel; nil for a footer that counts
    /// none. Only rows below the last rule are read: that rule is the bottom
    /// of the prompt box, so a transcript line quoting "2 shells" never counts.
    public static func reason(in screen: String) -> String? {
        let lines = screen.components(separatedBy: "\n")
        guard let rule = lines.lastIndex(where: { $0.wholeMatch(of: /\s*─{10,}\s*/) != nil }) else { return nil }
        let footer = lines[(rule + 1)...]
        for line in footer {
            let segment = line.components(separatedBy: " · ").first { $0.contains(/\b[1-9]\d* (?:shells?|monitors?)\b/) }
            if let segment { return segment.trimmingCharacters(in: .whitespaces) }
        }
        // The agents panel is drawn only while a subagent runs: `⏺ main`,
        // then one row per subagent.
        guard let main = footer.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "⏺ main" }) else { return nil }
        let subagents = footer[(main + 1)...].count { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        switch subagents {
        case 0: return nil
        case 1: return "1 subagent"
        default: return "\(subagents) subagents"
        }
    }
}

/// A status as flock draws it: herdr's, except that a Claude Code pane herdr
/// calls idle or done while its footer counts background work draws as
/// working, with the footer's reason beside it.
public struct ShownStatus: Equatable, Sendable {
    public let status: AgentStatus
    /// Set only on a pane herdr reports idle or done.
    public let backgroundWork: String?

    public init(_ status: AgentStatus, backgroundWork: String? = nil) {
        self.status = backgroundWork == nil ? status : .working
        self.backgroundWork = backgroundWork
    }

    public var isBackground: Bool { backgroundWork != nil }

    /// `working · 1 shell`.
    public var word: String {
        backgroundWork.map { "\(status.rawValue) · \($0)" } ?? status.rawValue
    }

    /// `backgroundWork` is `SessionViewModel.backgroundWork`. An entry for a
    /// pane that is no longer eligible is ignored, so a stale read can never
    /// relabel a pane that has since started working or been blocked.
    public static func of(_ pane: PaneRecord, backgroundWork: [PaneID: String]) -> ShownStatus {
        guard BackgroundWork.isEligible(pane), let reason = backgroundWork[pane.paneID] else {
            return ShownStatus(pane.agentStatus)
        }
        return ShownStatus(pane.agentStatus, backgroundWork: reason)
    }

    /// A tab's or a workspace's status: the loudest of its panes, as
    /// `AgentAttention.aggregate` ranks them, background work ranking as
    /// working. A pane really working outranks one busy in the background.
    /// `herdr` is what herdr reports for the group, kept when no pane in it
    /// is busy in the background.
    public static func aggregate(
        herdr: AgentStatus, panes: some Sequence<PaneRecord>, backgroundWork: [PaneID: String]
    ) -> ShownStatus {
        guard !backgroundWork.isEmpty else { return ShownStatus(herdr) }
        let shown = panes.map { of($0, backgroundWork: backgroundWork) }
        guard shown.contains(where: \.isBackground) else { return ShownStatus(herdr) }
        func rank(_ s: ShownStatus) -> (Int, Int) { (AgentAttention.rank(s.status), s.isBackground ? 0 : 1) }
        return shown.max { rank($0) < rank($1) } ?? ShownStatus(herdr)
    }
}
