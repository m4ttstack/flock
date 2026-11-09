import Foundation

/// rt's `chat.slackSupport.persona` names the agent a Slack support chat
/// talks to. Until rt answers, or when it has no such key, the copy keeps
/// naming Slack.
public struct ChatSlackPersona: Equatable, Sendable {
    public let name: String?

    public init(name: String?) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = (trimmed?.isEmpty == false) ? trimmed : nil
    }

    public static let unnamed = ChatSlackPersona(name: nil)

    public static let settingArguments = ["settings", "get", "chat.slackSupport.persona", "--json"]

    /// The feature row and the form's header.
    public var featureTitle: String { name.map { "\($0) Support Chat" } ?? "Slack support" }

    /// A chat in a sentence: "Opening Maude chat…", "End the Maude chat first".
    public var chatNoun: String { name.map { "\($0) chat" } ?? "Slack chat" }

    public static func decode(stdout: Data, exitCode: Int32) -> ChatSlackPersona {
        guard exitCode == 0, let reply = try? JSONDecoder().decode(Reply.self, from: stdout) else { return .unnamed }
        return ChatSlackPersona(name: reply.value?.name)
    }

    private struct Reply: Decodable {
        struct Value: Decodable { let name: String? }
        let value: Value?
    }
}
