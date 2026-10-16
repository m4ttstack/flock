import Foundation

protocol HerdrCommandRunner: Sendable {
    /// Runs `executable` with `arguments`; returns exit status and combined output.
    func run(_ executable: String, _ arguments: [String]) async -> (status: Int32, output: String)
}

/// stdin is /dev/null: herdr's prompts check for a terminal and take their
/// non-interactive answer without one. Output goes to a file rather than a
/// pipe, so a process herdr leaves running with the descriptor inherited
/// cannot hold the read open. No deadline: a handoff can take minutes, and
/// the section shows it running.
struct ProcessHerdrCommandRunner: HerdrCommandRunner {
    func run(_ executable: String, _ arguments: [String]) async -> (status: Int32, output: String) {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("flock-herdr-update-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: log) }
        guard FileManager.default.createFile(atPath: log.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: log) else {
            return (-1, "flock couldn't capture herdr's output")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ToolPath.childEnvironment()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = handle
        let (status, launchFailure): (Int32, String?) = await withCheckedContinuation { continuation in
            process.terminationHandler = { finished in continuation.resume(returning: (finished.terminationStatus, nil)) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: (-1, error.localizedDescription))
            }
        }
        try? handle.close()
        if let launchFailure { return (status, launchFailure) }
        return (status, (try? String(contentsOf: log, encoding: .utf8)) ?? "")
    }
}
