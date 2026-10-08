import Foundation
import Observation

/// The agent sessions a close would end: every pane herdr detected an agent
/// in, among the panes the close destroys (`BusyPanes.destroyed`). Idle
/// counts, because the conversation is the loss, not only the work in flight.
public struct AgentSessions: Equatable, Sendable {
    /// herdr's agent name, one per pane.
    public let agents: [String]

    public static let none = AgentSessions(agents: [])

    public var isEmpty: Bool { agents.isEmpty }

    public init(agents: [String]) {
        self.agents = agents
    }

    public init(closing subject: CloseSubject, consequence: CloseConsequence, model: SessionModel) {
        self.init(agents: BusyPanes.destroyed(by: subject, consequence: consequence, model: model).compactMap(\.agent))
    }

    var sentence: String? {
        guard let first = agents.first else { return nil }
        let name = agents.allSatisfy { $0 == first } ? Self.displayName(first) : "agent"
        return agents.count == 1
            ? "The close ends \(Self.article(name)) \(name) session."
            : "The close ends \(agents.count) \(name) sessions."
    }

    static func displayName(_ agent: String) -> String {
        switch agent {
        case "claude": "Claude Code"
        case "codex": "Codex"
        default: agent.prefix(1).uppercased() + agent.dropFirst()
        }
    }

    private static func article(_ name: String) -> String {
        "AEIOU".contains(name.prefix(1).uppercased()) ? "an" : "a"
    }
}

/// Settings > Closing > "Warn before closing an agent", and the close
/// prompt's "Don't warn me next time". On by default.
@MainActor
@Observable
public final class AgentCloseWarningStore {
    public static let defaultsKey = "flock.warnBeforeClosingAgents"

    public private(set) var active: Bool

    @ObservationIgnored private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        active = userDefaults.object(forKey: Self.defaultsKey) as? Bool ?? true
    }

    public func select(_ value: Bool) {
        active = value
        userDefaults.set(value, forKey: Self.defaultsKey)
    }
}
