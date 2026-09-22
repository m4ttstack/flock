import Foundation
import Observation

/// The workspace rail split into the workspaces a person watches and the
/// herds a shepherd watches for them.
///
/// A herd row carries no status of its own: every gate a worker raises is
/// the shepherd's to answer, so the rail reports only how far the herd has
/// got and whether anything in it is still moving.
public struct HerdRail: Equatable, Sendable {
    public struct Herd: Equatable, Sendable {
        public let workspaceID: WorkspaceID
        public let name: String
        public let done: Int
        public let total: Int
        public let isRunning: Bool

        /// A herd with no panes yet has not finished anything.
        public var isFinished: Bool { total > 0 && done == total }
    }

    /// Herds, never workers.
    public struct Summary: Equatable, Sendable {
        public let running: Int
        public let done: Int
        public let isAnyRunning: Bool

        /// Herds finished out of all herds, in the same N/M form each herd
        /// row uses for its workers. Whether anything is still moving is the
        /// glyph's to say, which is what lets this fit the default rail
        /// beside the heading and its chevron.
        public var text: String { "\(done)/\(running + done) done" }
    }

    public let workspaces: [WorkspaceRecord]
    public let herds: [Herd]

    /// `nil` when there are no herds, which hides the section outright.
    public var summary: Summary? {
        guard !herds.isEmpty else { return nil }
        let done = herds.filter(\.isFinished).count
        return Summary(running: herds.count - done, done: done, isAnyRunning: herds.contains(where: \.isRunning))
    }

    public init(model: SessionModel) {
        var statuses: [WorkspaceID: [AgentStatus]] = [:]
        for pane in model.panes.values {
            statuses[pane.workspaceID, default: []].append(pane.agentStatus)
        }
        var workspaces: [WorkspaceRecord] = []
        var herds: [Herd] = []
        for workspace in model.workspaces {
            guard HerdWorkspace.isHerd(label: workspace.label) else {
                workspaces.append(workspace)
                continue
            }
            let workers = statuses[workspace.workspaceID] ?? []
            herds.append(Herd(
                workspaceID: workspace.workspaceID,
                name: workspace.label.dropFirst(HerdWorkspace.labelPrefix.count).trimmingCharacters(in: .whitespaces),
                done: workers.filter(Self.isFinishedWorker).count,
                total: workers.count,
                isRunning: workers.contains(where: Self.isWorkingWorker)
            ))
        }
        self.workspaces = workspaces
        self.herds = herds
    }

    /// herdr reports an agent that finished its turn as `done` until someone
    /// looks at the pane and as `idle` after, so both mean finished here.
    public static func isFinishedWorker(_ status: AgentStatus) -> Bool {
        status == .done || status == .idle
    }

    /// A blocked worker is waiting on its shepherd, which is still a herd in
    /// motion.
    public static func isWorkingWorker(_ status: AgentStatus) -> Bool {
        status == .working || status == .blocked
    }

    /// The rail reorders regular workspaces among themselves, and herdr's
    /// `workspace.move` takes an index into its full list, herds included.
    /// A slot before the rail's `railIndex`th row lands before that same
    /// workspace; a slot past the last row lands just after the last one.
    public static func modelInsertIndex(forRailIndex railIndex: Int, in model: SessionModel) -> Int {
        let regularIndices = model.workspaces.indices.filter { !HerdWorkspace.isHerd(label: model.workspaces[$0].label) }
        if railIndex < regularIndices.count {
            return regularIndices[max(railIndex, 0)]
        }
        return (regularIndices.last.map { $0 + 1 }) ?? railIndex
    }
}

/// Whether the rail's Herds section is folded, across launches. Mirrors
/// `RailWidthStore`'s UserDefaults pattern, and is injected the same way.
/// Nothing but `toggle` writes it: a herd appearing while folded leaves it
/// folded, and the header's count is the notice.
@MainActor
@Observable
public final class HerdsSectionStore {
    public static let defaultsKey = "flock.herdsCollapsed"

    public private(set) var isCollapsed: Bool
    @ObservationIgnored private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        isCollapsed = userDefaults.bool(forKey: Self.defaultsKey)
    }

    public func toggle() {
        isCollapsed.toggle()
        userDefaults.set(isCollapsed, forKey: Self.defaultsKey)
    }
}
