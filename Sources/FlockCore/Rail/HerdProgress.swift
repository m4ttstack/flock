import Foundation

/// How far a herd has got by rt's own account of its workers, which is what a
/// herd row's N/M reports whenever rt has answered for that herd.
///
/// herdr can only say whether a pane's agent is busy; rt knows whether each
/// worker has turned in its result. A worker that has not started yet reads
/// idle to herdr, which counted it finished before it had done anything.
public struct HerdProgress: Equatable, Sendable {
    public let done: Int
    public let total: Int
    public let isRunning: Bool

    public init(done: Int, total: Int, isRunning: Bool) {
        self.done = done
        self.total = total
        self.isRunning = isRunning
    }

    /// `rt herd report` is a worker's final report and moves its job to
    /// `done`; a job the shepherd has closed is out of play either way.
    /// `crashed` is neither finished nor running, so a herd that lost a
    /// worker never reads as complete.
    public static func isFinished(jobStatus: String) -> Bool {
        jobStatus == "done" || jobStatus == "closed"
    }

    public static func isRunning(jobStatus: String) -> Bool {
        ["spawning", "active", "at-gate", "at-milestone", "stuck-at-modal"].contains(jobStatus)
    }

    /// `rt herd status --herd <id> --json`'s stdout, or nil for anything that
    /// is not that envelope.
    public static func fromHerdStatus(stdout: Data) -> HerdProgress? {
        guard let status = try? JSONDecoder().decode(HerdStatusEnvelope.self, from: stdout) else { return nil }
        let statuses = status.jobs.map(\.status)
        return HerdProgress(
            done: statuses.filter(isFinished(jobStatus:)).count,
            total: statuses.count,
            isRunning: statuses.contains(where: isRunning(jobStatus:))
        )
    }
}

/// One row of `rt herd list --json`: the herd's id, which `rt herd status`
/// takes, and the herdr workspace label rt gave the herd, which is how a rail
/// row finds its herd.
public struct ListedHerd: Equatable, Sendable {
    public let id: String
    public let workspaceLabel: String

    public init(id: String, workspaceLabel: String) {
        self.id = id
        self.workspaceLabel = workspaceLabel
    }

    public static func fromHerdList(stdout: Data) -> [ListedHerd]? {
        guard let list = try? JSONDecoder().decode(HerdListEnvelope.self, from: stdout) else { return nil }
        return list.herds.map { ListedHerd(id: $0.id, workspaceLabel: $0.workspace) }
    }
}

private struct HerdListEnvelope: Decodable {
    struct Herd: Decodable {
        let id: String
        let workspace: String
    }

    let herds: [Herd]
}

private struct HerdStatusEnvelope: Decodable {
    struct Job: Decodable {
        let status: String
    }

    let jobs: [Job]
}
