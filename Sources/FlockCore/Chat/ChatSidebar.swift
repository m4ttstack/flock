import Foundation

/// One open Slack chat, as `rt chat slack-status --json` prints it. `pane` is
/// absent once the agent holding the chat has no presence.
public struct ChatSidebarChat: Decodable, Equatable, Sendable {
    public let room: String
    public var pane: String? = nil
    public let name: String
    public var displayName: String? = nil

    public var shownName: String {
        displayName.flatMap { $0.isEmpty ? nil : $0 } ?? name
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

    /// The focused pane's chat wins, then the one already shown, so moving to
    /// a pane with no chat does not swap the conversation being read.
    public static func next(
        current: ChatSidebarSelection?, open: [ChatSidebarChat], focusedPane: String?
    ) -> ChatSidebarSelection? {
        if let focusedPane, let chat = open.first(where: { $0.pane == focusedPane }) {
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
