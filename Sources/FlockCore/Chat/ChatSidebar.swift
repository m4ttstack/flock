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
    /// The pane rt recorded as the one that asked for the chat.
    public var requesterPane: String? = nil
    public var assignedPane: String? = nil
    /// What `slack-resume` takes once the chat has closed.
    public var id: Int? = nil

    private enum CodingKeys: String, CodingKey { case room, pane, name, displayName, requesterPane, assignedPane, id }

    public init(
        room: String, pane: String? = nil, name: String, displayName: String? = nil, linkedPane: String? = nil,
        requesterPane: String? = nil, assignedPane: String? = nil, id: Int? = nil
    ) {
        self.room = room
        self.pane = pane
        self.name = name
        self.displayName = displayName
        self.linkedPane = linkedPane
        self.requesterPane = requesterPane
        self.assignedPane = assignedPane
        self.id = id
    }

    public var shownName: String {
        displayName.flatMap { $0.isEmpty ? nil : $0 } ?? name
    }

    /// The pane this chat belongs to on screen.
    public var homePane: String? {
        linkedPane ?? requesterPane ?? pane
    }

    /// The pane of the agent holding the chat, which is what closing it names.
    public var agentPane: String? {
        pane ?? assignedPane
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
    /// background agent started outside Flock has no pane on any tab, so its
    /// chat shows on none.
    public func isLinked(toTab panes: Set<String>) -> Bool {
        guard let pane = chat.homePane, !pane.hasPrefix("bg:") else { return false }
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

/// What a Slack chat's background agent needs from Flock: how long a started
/// chat has to appear in rt's list, and the line and delay that end an agent an
/// older Flock started.
public enum ChatSlackAgent {
    public static let exitLine = "/exit"
    /// Past this with no chat listed, a started chat is not coming.
    public static let openDeadline: Duration = .seconds(60)
    /// The agent's outcome DM to the operator goes out after the chat closes.
    public static let exitDelay: Duration = .seconds(30)
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
