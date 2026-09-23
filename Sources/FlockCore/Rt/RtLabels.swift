import Foundation

public enum RtKind: String, Sendable, CaseIterable {
    case nav, glitter, run, runner
}

/// How flock marks what it owns in herdr. The workspace label is the whole
/// test for "hidden from every surface"; a tab label links the tab to the pane
/// that opened it, by that pane's terminal, and names its files by token.
public enum RtLabels {
    public static let sharedWorkspace = "flock:rt"
    public static let runnerWorkspacePrefix = "flock:rt runner "

    public static func isFlockOwned(workspaceLabel label: String) -> Bool {
        label == sharedWorkspace || label.hasPrefix(runnerWorkspacePrefix)
    }

    public static func runnerWorkspaceLabel(linkedTo terminal: TerminalID) -> String {
        runnerWorkspacePrefix + terminal.rawValue
    }

    public struct TabLink: Equatable, Sendable {
        public let kind: RtKind
        public let terminal: TerminalID
        public let token: String

        public init(kind: RtKind, terminal: TerminalID, token: String) {
            self.kind = kind
            self.terminal = terminal
            self.token = token
        }
    }

    public static func tabLabel(_ link: TabLink) -> String {
        "\(link.kind.rawValue) \(link.terminal.rawValue) \(link.token)"
    }

    public static func tabLink(fromLabel label: String) -> TabLink? {
        let parts = label.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let kind = RtKind(rawValue: parts[0]), !parts[1].isEmpty, !parts[2].isEmpty else {
            return nil
        }
        return TabLink(kind: kind, terminal: TerminalID(rawValue: parts[1]), token: parts[2])
    }
}
