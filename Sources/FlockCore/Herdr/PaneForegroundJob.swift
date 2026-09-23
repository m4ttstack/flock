import Foundation

/// Whether a pane's shell is back at its prompt, read from a
/// `pane.process_info` answer.
///
/// Busy is any foreground process that is not the shell itself, never the
/// process group alone: a job a shell starts without job control (a command
/// substitution, say) stays in the shell's own group.
public enum PaneForegroundJob {
    public struct Snapshot: Equatable, Sendable {
        public let busy: Bool
        /// The shell's own process name while it is in the foreground list,
        /// which is only while it sits at its prompt.
        public let shellName: String?
        /// Everything but the shell that holds the foreground.
        public let foregroundNames: [String]
    }

    public static func snapshot(processInfoResponse data: Data) -> Snapshot? {
        guard let info = try? JSONDecoder().decode(Envelope.self, from: data).result.processInfo,
              let shellPID = info.shellPID
        else { return nil }
        let processes = info.foregroundProcesses ?? []
        let busy: Bool
        if !processes.isEmpty {
            busy = processes.contains { $0.pid != shellPID }
        } else if let group = info.foregroundProcessGroupID {
            busy = group != shellPID
        } else {
            return nil
        }
        return Snapshot(
            busy: busy,
            shellName: processes.first { $0.pid == shellPID }?.name,
            foregroundNames: processes.filter { $0.pid != shellPID }.compactMap(\.name)
        )
    }

    /// `nil` when the answer cannot say: an error, or no `shell_pid` to
    /// compare against.
    public static func isBusy(processInfoResponse data: Data) -> Bool? {
        snapshot(processInfoResponse: data)?.busy
    }

    private struct Envelope: Decodable {
        struct Result: Decodable {
            let processInfo: Info
            enum CodingKeys: String, CodingKey { case processInfo = "process_info" }
        }
        let result: Result
    }

    private struct Info: Decodable {
        struct Process: Decodable { let pid: Int; let name: String? }
        let shellPID: Int?
        let foregroundProcessGroupID: Int?
        let foregroundProcesses: [Process]?

        enum CodingKeys: String, CodingKey {
            case shellPID = "shell_pid"
            case foregroundProcessGroupID = "foreground_process_group_id"
            case foregroundProcesses = "foreground_processes"
        }
    }
}
