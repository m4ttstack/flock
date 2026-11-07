import Foundation

/// What a pane's `status` says about Slack support. `unsupported` is a
/// herdr-chat that printed no `slackChat` key, which is not `noChat`: `noChat`
/// offers the form, and the form would type a command nothing there handles.
public enum ChatSlackState: Equatable, Sendable {
    case unsupported
    case noChat
    case open(name: String)
}

/// A wait the store runs for one pane, never proof of anything.
public enum ChatSlackTransition: Equatable, Sendable {
    case opening
    case closing
}

/// What the popover's Slack row draws. `slackChat` alone says a chat exists:
/// a transition only says what the row is waiting to see.
public enum ChatSlackRow: Equatable, Sendable {
    case available
    case opening
    case open(name: String)
    case closing(name: String)

    public static func resolve(status: ChatStatus?, transition: ChatSlackTransition?) -> ChatSlackRow? {
        guard let status, status.signedIn else { return nil }
        switch status.slack {
        case .unsupported:
            return nil
        case .noChat:
            return transition == .opening ? .opening : .available
        case let .open(name):
            return transition == .closing ? .closing(name: name) : .open(name: name)
        }
    }

    /// A sign-out closes the chat at once with no goodbye to the teammate,
    /// where End chat lets the pane write one.
    public var blocksSignOut: Bool {
        switch self {
        case .open, .closing: true
        case .available, .opening: false
        }
    }
}

/// Nothing opens a chat by typing any more. `rt pane send` only ends the
/// agents an older Flock started.
public enum ChatSlackCommand {
    /// rt waits for the pane to take the prompt, nudges it once and waits
    /// again, so the text can land after any shorter deadline has fired.
    public static let sendDeadline: Duration = .seconds(20)

    public static func sendArguments(pane: String, line: String) -> [String] {
        ["pane", "send", pane, "--text", line, "--json"]
    }

    /// The daemon refuses this command from any caller that names a pane.
    public static func sendEnvironment(_ base: [String: String]) -> [String: String] {
        var environment = base
        environment["HERDR_PANE_ID"] = nil
        return environment
    }

    /// Why the pane turned the text away, or nil. rt answers `queued` for a
    /// slash command that ran and a failed call says nothing either way, so
    /// only `refused` means nothing was typed.
    public static func refusal(stdout: Data, exitCode: Int32) -> String? {
        guard exitCode == 0, let reply = try? JSONDecoder().decode(SendReply.self, from: stdout),
              reply.delivered == "refused"
        else { return nil }
        return reply.reason ?? "the pane refused it"
    }

    private struct SendReply: Decodable {
        let delivered: String
        let reason: String?
    }
}

/// How the store waits on `slackChat` after On or Off, in polls of `status`.
public enum ChatSlackWatch {
    /// An open takes about 15 seconds, more behind a slow prompt.
    public static let openInterval: Duration = .seconds(1)
    public static let openAttempts = 30
    /// A close gives the pane 2 minutes to say goodbye.
    public static let closeInterval: Duration = .seconds(3)
    public static let closeAttempts = 50
}

/// One person a chat can reach. `person` is the Slack id: the line types that,
/// because a name can be one the open would not match. `name` is display only.
public struct ChatSlackPerson: Decodable, Equatable, Identifiable, Sendable {
    public let name: String
    public let person: String
    public var title: String? = nil

    public var id: String { person }
}

/// What `slack-people` prints. No list means Slack is not connected, and the
/// form falls back to a typed name.
public struct ChatSlackPeople: Decodable, Equatable, Sendable {
    public let people: [ChatSlackPerson]?
}

/// The form's search. It filters a list fetched once, because Slack limits how
/// often that list can be read.
public enum ChatSlackPeopleSearch {
    public static let limit = 4

    /// Word starts first, so "al" finds Alex ahead of Sal.
    public static func matches(_ query: String, in people: [ChatSlackPerson]) -> [ChatSlackPerson] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return [] }
        let found = people.filter { $0.name.lowercased().contains(query) }
        let wordStarts = found.filter { startsAWord($0.name, query) }
        let inside = found.filter { !startsAWord($0.name, query) }
        return Array((wordStarts + inside).prefix(limit))
    }

    /// Only two people sharing a name need telling apart.
    public static func titleToShow(for person: ChatSlackPerson, among results: [ChatSlackPerson]) -> String? {
        results.filter { $0.name == person.name }.count > 1 ? person.title : nil
    }

    private static func startsAWord(_ name: String, _ query: String) -> Bool {
        name.lowercased().hasPrefix(query)
            || name.lowercased().split(whereSeparator: \.isWhitespace).contains { $0.hasPrefix(query) }
    }
}

/// The form's Person box: what is typed, who was picked, and which result the
/// arrow keys are on.
public struct ChatSlackPersonEntry: Equatable, Sendable {
    public private(set) var query: String
    public private(set) var picked: ChatSlackPerson?
    public private(set) var highlighted = 0

    public init(query: String = "", picked: ChatSlackPerson? = nil) {
        self.query = query
        self.picked = picked
    }

    /// AppKit writes a field's value back as it loses focus, so unchanged
    /// text is not typing and must not undo a pick.
    public mutating func type(_ text: String) {
        guard text != query else { return }
        query = text
        picked = nil
        highlighted = 0
    }

    public mutating func pick(_ person: ChatSlackPerson) {
        query = person.name
        picked = person
        highlighted = 0
    }

    public mutating func moveHighlight(by step: Int, among count: Int) {
        guard count > 0 else { return }
        highlighted = (highlighted + step + count) % count
    }
}

/// What `slack-close` prints. A close by pane answers `closed: false` while
/// the pane says goodbye, so the store follows `slackChat`, not this.
public struct ChatSlackClosed: Decodable, Equatable, Sendable {
    public let closed: Bool
}

/// How a `slack-start` or `slack-resume` call ended. rt prints its refusal in
/// the envelope, so a failure carries the sentence a person reads.
public enum ChatSlackOutcome: Equatable, Sendable {
    case done
    case failed(String)

    static func decode(stdout: Data, exitCode: Int32) -> ChatSlackOutcome {
        let reply = try? JSONDecoder().decode(Reply.self, from: stdout)
        if exitCode == 0, reply?.ok == true { return .done }
        return .failed(reply?.error ?? "rt gave no answer")
    }

    private struct Reply: Decodable {
        let ok: Bool?
        let error: String?
    }
}

/// Start has a verb of its own: rt works out the repo from the folder it runs
/// in, takes the brief from stdin so no line is typed anywhere, and records the
/// pane that asked.
public enum ChatSlackStart {
    /// rt waits for the agent to launch and settle before it answers.
    public static let deadline: Duration = .seconds(60)

    public static func canStart(person: String, problem: String) -> Bool {
        !person.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !problem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public static func arguments(person: String, requesterPane: String) -> [String] {
        ["chat", "slack-start", person, "--brief", "-", "--requester-pane", requesterPane, "--json"]
    }

    /// A caller naming a pane or session would be read as the requester.
    public static func environment(_ base: [String: String]) -> [String: String] {
        var environment = base
        environment["HERDR_PANE_ID"] = nil
        environment["CLAUDE_CODE_SESSION_ID"] = nil
        return environment
    }

    public static func outcome(stdout: Data, exitCode: Int32) -> ChatSlackOutcome {
        ChatSlackOutcome.decode(stdout: stdout, exitCode: exitCode)
    }
}

/// The tap on Resume is the operator's own approval, so rt asks no one else.
public enum ChatSlackResume {
    public static let deadline: Duration = .seconds(60)

    public static func arguments(conversation: Int) -> [String] {
        ["chat", "slack-resume", String(conversation), "--approved", "--json"]
    }

    public static func outcome(stdout: Data, exitCode: Int32) -> ChatSlackOutcome {
        ChatSlackOutcome.decode(stdout: stdout, exitCode: exitCode)
    }
}
