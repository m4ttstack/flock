import Foundation

/// Whether a pane's shell is back at its prompt, read from a
/// `pane.process_info` answer.
///
/// Busy is any foreground process that is not the shell itself, never the
/// process group alone: a job a shell starts without job control (a command
/// substitution, say) stays in the shell's own group.
public enum PaneForegroundJob {
    /// `nil` when the answer cannot say: an error, or no `shell_pid` to
    /// compare against.
    public static func isBusy(processInfoResponse data: Data) -> Bool? {
        guard let info = try? JSONDecoder().decode(Envelope.self, from: data).result.processInfo,
              let shellPID = info.shellPID
        else { return nil }
        if let processes = info.foregroundProcesses, !processes.isEmpty {
            return processes.contains { $0.pid != shellPID }
        }
        guard let group = info.foregroundProcessGroupID else { return nil }
        return group != shellPID
    }

    private struct Envelope: Decodable {
        struct Result: Decodable {
            let processInfo: Info
            enum CodingKeys: String, CodingKey { case processInfo = "process_info" }
        }
        let result: Result
    }

    private struct Info: Decodable {
        struct Process: Decodable { let pid: Int }
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
