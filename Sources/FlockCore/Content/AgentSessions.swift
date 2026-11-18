import Foundation
import Observation

/// The agent sessions a close would end: every pane herdr detected an agent
/// in, among the panes the close destroys (`BusyPanes.destroyed`). Idle
/// counts, because the conversation is the loss, not only the work in flight.
public struct AgentSessions: Equatable, Sendable {
    /// herdr's agent name, one per pane.
    public let agents: [String]
    /// Every pane the close destroys, agent or not.
    public let panes: Int

    public static let none = AgentSessions(agents: [])

    public var isEmpty: Bool { agents.isEmpty }

    public init(agents: [String], panes: Int? = nil) {
        self.agents = agents
        self.panes = panes ?? agents.count
    }

    public init(closing subject: CloseSubject, consequence: CloseConsequence, model: SessionModel) {
        let destroyed = BusyPanes.destroyed(by: subject, consequence: consequence, model: model)
        self.init(agents: destroyed.compactMap(\.agent), panes: destroyed.count)
    }
}

/// Settings > Closing, one switch for tabs and one for panes, and the close
/// prompt's "Don't warn me next time", which turns off the one for what was
/// being closed. Both on by default.
@MainActor
@Observable
public final class AgentCloseWarningStore {
    public enum Kind: String, CaseIterable, Sendable {
        case tab, pane

        /// A pane close that takes its tab is still a pane close: that is what
        /// was asked for.
        public init(_ subject: CloseSubject) {
            switch subject {
            case .tab: self = .tab
            case .pane: self = .pane
            }
        }
    }

    /// The one switch there was before tabs and panes had their own; what it
    /// held is where both start.
    public static let legacyDefaultsKey = "flock.warnBeforeClosingAgents"

    public static func defaultsKey(for kind: Kind) -> String {
        switch kind {
        case .tab: "flock.warnBeforeClosingAgentTabs"
        case .pane: "flock.warnBeforeClosingAgentPanes"
        }
    }

    private var warnings: [Kind: Bool]

    @ObservationIgnored private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let legacy = userDefaults.object(forKey: Self.legacyDefaultsKey) as? Bool ?? true
        warnings = Dictionary(uniqueKeysWithValues: Kind.allCases.map {
            ($0, userDefaults.object(forKey: Self.defaultsKey(for: $0)) as? Bool ?? legacy)
        })
    }

    public func warns(on kind: Kind) -> Bool { warnings[kind] ?? true }

    public func select(_ value: Bool, for kind: Kind) {
        warnings[kind] = value
        userDefaults.set(value, forKey: Self.defaultsKey(for: kind))
    }
}
