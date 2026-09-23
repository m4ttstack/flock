import Foundation

/// One `rt` invocation for a read flock makes on its own, outside chat: the
/// Board setting, a herd's progress.
enum RtCommand {
    static let deadline: Duration = .seconds(5)

    /// stdout and exit status, or nil when rt is not installed or did not run
    /// to an exit.
    @Sendable
    static func run(_ arguments: [String]) async -> (stdout: Data, exitCode: Int32)? {
        let resolved = await Task.detached(priority: .utility) { () -> (rt: String, environment: [String: String])? in
            guard let rt = ToolPath.resolve("rt") else { return nil }
            return (rt, ToolPath.childEnvironment())
        }.value
        guard let resolved else { return nil }
        return try? await ToolRunner(binaryPath: resolved.rt, environment: resolved.environment, deadline: deadline)
            .run(arguments)
    }
}
