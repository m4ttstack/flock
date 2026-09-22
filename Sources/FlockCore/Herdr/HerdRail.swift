import Foundation

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

    /// `progress` is rt's count for each herd it answered for, keyed by
    /// workspace label. A herd without one is counted from herdr's panes,
    /// which is the best there is until rt answers, or where rt is absent.
    public init(model: SessionModel, progress: [String: HerdProgress] = [:]) {
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
            let counted = progress[workspace.label] ?? HerdProgress(
                done: workers.filter(Self.isFinishedWorker).count,
                total: workers.count,
                isRunning: workers.contains(where: Self.isWorkingWorker)
            )
            herds.append(Herd(
                workspaceID: workspace.workspaceID,
                name: workspace.label.dropFirst(HerdWorkspace.labelPrefix.count).trimmingCharacters(in: .whitespaces),
                done: counted.done,
                total: counted.total,
                isRunning: counted.isRunning
            ))
        }
        self.workspaces = workspaces
        self.herds = Self.displayNamed(herds)
    }

    /// rt mints a herd id as `<name>-YYYYMMDD-HHMMSS`, plus `-N` when that
    /// collides (`mintHerdId` in rt's herd store). The stamp is for
    /// uniqueness, not for reading, and at rail width it was most of what
    /// showed. Only that exact suffix is taken off, so a name that merely
    /// ends in digits keeps them.
    static func stripStamp(_ id: String) -> (name: String, time: String?) {
        let pattern = #"^(.+)-(\d{8})-(\d{2})(\d{2})(\d{2})(?:-\d+)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: id, range: NSRange(id.startIndex..., in: id)),
              let name = Range(match.range(at: 1), in: id),
              let hours = Range(match.range(at: 3), in: id),
              let minutes = Range(match.range(at: 4), in: id)
        else { return (id, nil) }
        return (String(id[name]), "\(id[hours]):\(id[minutes])")
    }

    /// Two herds started under one name would read identically once their
    /// stamps are gone, so those two, and only those, get their start time
    /// back.
    static func displayNamed(_ herds: [Herd]) -> [Herd] {
        let stripped = herds.map { stripStamp($0.name) }
        var counts: [String: Int] = [:]
        for entry in stripped { counts[entry.name, default: 0] += 1 }
        return zip(herds, stripped).map { herd, entry in
            let shared = (counts[entry.name] ?? 0) > 1
            let name = shared ? entry.time.map { "\(entry.name) \($0)" } ?? herd.name : entry.name
            return Herd(
                workspaceID: herd.workspaceID, name: name, done: herd.done, total: herd.total,
                isRunning: herd.isRunning
            )
        }
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
}
