import Foundation

protocol HerdrCommandRunner: Sendable {
    /// Runs `executable` with `arguments`; returns exit status and combined output.
    func run(_ executable: String, _ arguments: [String]) async -> (status: Int32, output: String)
}

/// stdin is /dev/null: herdr's prompts check for a terminal and take their
/// non-interactive answer without one. Output goes to a file rather than a
/// pipe, so a process herdr leaves running with the descriptor inherited
/// cannot hold the read open. The deadline sits well past herdr's own
/// handoff timeouts (240s request, 30s confirm), so only a wedged run reaches it.
struct ProcessHerdrCommandRunner: HerdrCommandRunner {
    static let timedOutOutput = "timed out"

    var deadline: Duration = .seconds(600)
    var environment: @Sendable () -> [String: String] = { ToolPath.childEnvironment() }

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
        process.environment = environment()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = handle
        let child = Child(process)
        let deadline = deadline
        let (status, launchFailure): (Int32, String?) = await withCheckedContinuation { continuation in
            process.terminationHandler = { finished in continuation.resume(returning: (finished.terminationStatus, nil)) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: (-1, error.localizedDescription))
                return
            }
            child.startTimer(deadline)
        }
        child.stopTimer()
        try? handle.close()
        if let launchFailure { return (status, launchFailure) }
        if child.timedOut { return (status == 0 ? -1 : status, Self.timedOutOutput) }
        return (status, (try? String(contentsOf: log, encoding: .utf8)) ?? "")
    }
}

/// `@unchecked Sendable`: the timer task and the awaiting caller both reach
/// the process; `lock` is what makes that safe, not `Process` itself.
private final class Child: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private var timer: Task<Void, Never>?
    private var expired = false

    init(_ process: Process) { self.process = process }

    var timedOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return expired
    }

    /// Started only once `run()` has returned: `terminate()` on a process
    /// that has not launched is undefined.
    func startTimer(_ deadline: Duration) {
        lock.lock()
        defer { lock.unlock() }
        timer = Task { [weak self] in
            try? await Task.sleep(for: deadline)
            guard !Task.isCancelled else { return }
            self?.expire()
        }
    }

    func stopTimer() {
        lock.lock()
        defer { lock.unlock() }
        timer?.cancel()
    }

    private func expire() {
        lock.lock()
        defer { lock.unlock() }
        guard process.isRunning else { return }
        expired = true
        process.terminate()
    }
}
