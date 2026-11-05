import Foundation

/// One open Slack chat, as `rt chat slack-status --json` prints it. `pane` is
/// absent once the agent holding the chat has no presence.
public struct ChatSidebarChat: Decodable, Equatable, Sendable {
    public let room: String
    public var pane: String? = nil
    public let name: String
    public var displayName: String? = nil
    /// The pane a background agent's chat was started from. Only Flock knows it.
    public var linkedPane: String? = nil

    private enum CodingKeys: String, CodingKey { case room, pane, name, displayName }

    public init(room: String, pane: String? = nil, name: String, displayName: String? = nil, linkedPane: String? = nil) {
        self.room = room
        self.pane = pane
        self.name = name
        self.displayName = displayName
        self.linkedPane = linkedPane
    }

    public var shownName: String {
        displayName.flatMap { $0.isEmpty ? nil : $0 } ?? name
    }

    /// The pane this chat belongs to on screen.
    public var homePane: String? {
        linkedPane ?? pane
    }
}

public struct ChatSidebarChats: Decodable, Equatable, Sendable {
    public let conversations: [ChatSidebarChat]

    /// Nil for anything rt did not answer: that says nothing about which
    /// chats are open, so it must not read as "none are".
    public static func decode(stdout: Data, exitCode: Int32) -> [ChatSidebarChat]? {
        guard exitCode == 0 else { return nil }
        return (try? JSONDecoder().decode(ChatSidebarChats.self, from: stdout))?.conversations
    }
}

/// What the sidebar shows. An ended chat stays until it is dismissed, so its
/// last messages can still be read.
public struct ChatSidebarSelection: Equatable, Sendable {
    public let chat: ChatSidebarChat
    public let isEnded: Bool

    public init(chat: ChatSidebarChat, isEnded: Bool) {
        self.chat = chat
        self.isEnded = isEnded
    }

    /// A chat belongs to its pane, so it shows only on that pane's tab. A
    /// background agent started outside Flock has no pane on any tab.
    public func isLinked(toTab panes: Set<String>) -> Bool {
        guard let pane = chat.homePane, !pane.hasPrefix("bg:") else { return true }
        return panes.contains(pane)
    }

    /// The focused pane's chat wins, then a chat on this tab over one that
    /// isn't, then the one already shown, so moving to a pane with no chat
    /// does not swap the conversation being read.
    public static func next(
        current: ChatSidebarSelection?, open: [ChatSidebarChat], focusedPane: String?, tabPanes: Set<String>
    ) -> ChatSidebarSelection? {
        if let focusedPane, let chat = open.first(where: { $0.homePane == focusedPane }) {
            return ChatSidebarSelection(chat: chat, isEnded: false)
        }
        if current?.isLinked(toTab: tabPanes) != true,
           let chat = open.first(where: { $0.homePane.map(tabPanes.contains) == true }) {
            return ChatSidebarSelection(chat: chat, isEnded: false)
        }
        if let current {
            if let chat = open.first(where: { $0.room == current.chat.room }) {
                return ChatSidebarSelection(chat: chat, isEnded: false)
            }
            return ChatSidebarSelection(chat: current.chat, isEnded: true)
        }
        return open.first.map { ChatSidebarSelection(chat: $0, isEnded: false) }
    }
}

/// The background agent a Slack chat runs on, so the chat stays out of the
/// pane it was started from.
public enum ChatSlackAgent {
    public static let exitLine = "/exit"
    /// An agent has to launch and settle before `rt agent start` answers.
    public static let startDeadline: Duration = .seconds(60)
    /// Past this with no chat, the agent turned the command away. Its reason
    /// is on a screen nobody can see.
    public static let openDeadline: Duration = .seconds(60)
    /// The agent's outcome DM to the operator goes out after the chat closes.
    public static let exitDelay: Duration = .seconds(30)
    public static let sendAttempts = 10
    public static let sendRetryDelay: Duration = .seconds(2)

    public static func startArguments(repo: String) -> [String] {
        ["agent", "start", "--bg", "--repo", repo, "--label", "slack-support", "--json"]
    }

    public static func pane(stdout: Data, exitCode: Int32) -> String? {
        guard exitCode == 0 else { return nil }
        return (try? JSONDecoder().decode(Started.self, from: stdout))?.agent.paneId
    }

    public static func peekArguments(pane: String) -> [String] {
        ["pane", "peek", pane, "--lines", "40", "--json"]
    }

    /// Why the agent's screen says the chat did not open, or nil. A long
    /// reason wraps, and a blank line ends it.
    public static func refusal(stdout: Data, exitCode: Int32) -> String? {
        let marker = "The Slack chat did not open: "
        guard exitCode == 0, let lines = (try? JSONDecoder().decode(Peek.self, from: stdout))?.lines,
              let start = lines.lastIndex(where: { $0.contains(marker) }),
              let found = lines[start].range(of: marker)
        else { return nil }
        var parts = [String(lines[start][found.upperBound...])]
        for line in lines[(start + 1)...] {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.isEmpty { break }
            parts.append(text)
        }
        return parts.joined(separator: " ")
    }

    private struct Peek: Decodable {
        let lines: [String]
    }

    private struct Started: Decodable {
        let agent: Agent

        struct Agent: Decodable {
            let paneId: String
        }
    }
}

/// A repo the agent can read, always its main checkout: a worktree can vanish
/// mid-chat, and it holds someone's unfinished work.
public struct ChatSlackRepo: Identifiable, Equatable, Sendable {
    public let path: String

    public var id: String { path }
    public var name: String { URL(fileURLWithPath: path).lastPathComponent }

    public init(path: String) {
        self.path = path
    }

    /// `current` first, as the form's default. Touches the disk.
    public static func list(current: String, others: [String]) -> [ChatSlackRepo] {
        let first = MainCheckout.resolve(from: current) ?? current
        let rest = Set(others.compactMap(MainCheckout.resolve(from:))).subtracting([first])
        return [ChatSlackRepo(path: first)] + rest.map(ChatSlackRepo.init(path:)).sorted { $0.name < $1.name }
    }
}

/// Where the chat app's embed page is. `chat.mattstack` redirects into the
/// viewer app, so a web view has to use the local port deck reports.
public enum ChatEmbedAddress {
    /// `deck list` has no JSON form. Each row reads `name port state owner`.
    public static func port(deckList: String) -> Int? {
        for line in deckList.split(separator: "\n") {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 3, fields[0] == "chat", fields[2] == "up" else { continue }
            return Int(fields[1])
        }
        return nil
    }

    public static func url(port: Int, room: String) -> URL? {
        var segment = CharacterSet.urlPathAllowed
        segment.remove("/")
        guard let encoded = room.addingPercentEncoding(withAllowedCharacters: segment) else { return nil }
        return URL(string: "http://localhost:\(port)/embed/r/\(encoded)")
    }

    /// The page reads this once at load, so a theme change has to reload it.
    public static func themed(_ url: URL, isDark: Bool) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.queryItems = [URLQueryItem(name: "theme", value: isDark ? "dark" : "light")]
        return components.url ?? url
    }
}
