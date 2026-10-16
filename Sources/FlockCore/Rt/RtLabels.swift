import Foundation

public enum RtKind: String, Sendable, CaseIterable {
    case cd, nav, glitter, run, runner
}

/// How flock marks what it owns in herdr. The workspace label is the whole
/// test for "hidden from every surface"; a tab label links the tab to the pane
/// that opened it, by that pane's terminal and pane id, and names its files by
/// token. A runner workspace's label keeps the terminal it was opened with.
public enum RtLabels {
    public static let sharedWorkspace = "flock:rt"
    public static let runnerWorkspacePrefix = "flock:rt runner "

    public static func isFlockOwned(workspaceLabel label: String) -> Bool {
        label == sharedWorkspace || label.hasPrefix(runnerWorkspacePrefix)
    }

    public static func runnerWorkspaceLabel(linkedTo terminal: TerminalID) -> String {
        runnerWorkspacePrefix + terminal.rawValue
    }

    /// `pane` is the linked pane's public id: a herdr handoff gives every pane
    /// a new terminal but keeps its pane id. nil for a label written before
    /// pane ids were recorded.
    public struct TabLink: Equatable, Sendable {
        public let kind: RtKind
        public let terminal: TerminalID
        public let token: String
        public let pane: PaneID?

        public init(kind: RtKind, terminal: TerminalID, token: String, pane: PaneID? = nil) {
            self.kind = kind
            self.terminal = terminal
            self.token = token
            self.pane = pane
        }
    }

    /// A pane id with a space would not parse back, so it is left out.
    public static func tabLabel(_ link: TabLink) -> String {
        let base = "\(link.kind.rawValue) \(link.terminal.rawValue) \(link.token)"
        guard let pane = link.pane?.rawValue, !pane.isEmpty, !pane.contains(" ") else { return base }
        return base + " " + pane
    }

    public static func tabLink(fromLabel label: String) -> TabLink? {
        let parts = label.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 || parts.count == 4, !parts.contains(where: \.isEmpty),
              let kind = RtKind(rawValue: parts[0])
        else {
            return nil
        }
        let pane = parts.count == 4 ? PaneID(rawValue: parts[3]) : nil
        return TabLink(kind: kind, terminal: TerminalID(rawValue: parts[1]), token: parts[2], pane: pane)
    }
}
