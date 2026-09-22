import Foundation

/// One `rt` invocation for a read flock makes on its own, outside chat: the
/// Board setting, a herd's progress.
enum RtCommand {
    static let deadline: Duration = .seconds(5)

    /// stdout and exit status, or nil when rt is not installed or did not run
    /// to an exit.
    @Sendable
    static func run(_ arguments: [String]) async -> (stdout: Data, exitCode: Int32)? {
        let resolved = await Task.detached(priority: .utility) { () -> (rt: String, path: String)? in
            guard let rt = ToolPath.resolve("rt") else { return nil }
            return (rt, ToolPath.resolved)
        }.value
        guard let resolved else { return nil }
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = resolved.path
        // rt offers a picker wherever an argument is missing and stdin is a
        // terminal, which it is when flock was started from one; batch mode
        // rules that out.
        environment["RT_BATCH"] = "1"
        return try? await ToolRunner(binaryPath: resolved.rt, environment: environment, deadline: deadline).run(arguments)
    }
}
