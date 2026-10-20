import Foundation

/// Runs one tool as a child process under a hard deadline.
///
/// `Process` is not `Sendable`, so every touch of it lives inside `Child`,
/// which this type hands to a dedicated thread and never opens itself: the
/// caller's actor only ever awaits a continuation, so a `MainActor` caller is
/// never the thread that blocks on the child's exit.
struct ToolRunner: Sendable {
    enum Failure: Error, Equatable {
        case didNotStart(String)
        case timedOut
        case noResult
    }

    let binaryPath: String
    /// nil inherits this process's own environment.
    let environment: [String: String]?
    let deadline: Duration

    init(binaryPath: String, environment: [String: String]? = nil, deadline: Duration) {
        self.binaryPath = binaryPath
        self.environment = environment
        self.deadline = deadline
    }

    func run(_ arguments: [String]) async throws -> (stdout: Data, exitCode: Int32) {
        let output = try await run(arguments, capturingStderr: false)
        return (output.stdout, output.exitCode)
    }

    func runCapturingStderr(_ arguments: [String]) async throws -> (stdout: Data, stderr: Data, exitCode: Int32) {
        let output = try await run(arguments, capturingStderr: true)
        return (output.stdout, output.stderr, output.exitCode)
    }

    private func run(_ arguments: [String], capturingStderr: Bool) async throws -> Output {
        let child = Child(
            binaryPath: binaryPath, arguments: arguments, environment: environment, capturesStderr: capturingStderr
        )

        // A caller's `.task` is cancelled on teardown, not just timed out:
        // without this handler, the caller's own cancellation reaches only
        // the sleep race-partner below (which throws immediately) and never
        // the child, leaving it orphaned behind a read that never unblocks --
        // the exact hang the deadline exists to prevent, reached through
        // cancellation instead.
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Race.self) { group in
                group.addTask { .finished(try await Self.runToCompletion(child)) }
                group.addTask {
                    try await Task.sleep(for: self.deadline)
                    return .timedOut
                }
                // Whichever of the two finishes first decides the call; `cancelAll`
                // then reaches for the loser -- the sleep, cancelled instantly, or
                // the reader, which only a `terminate()` call (the `.timedOut`
                // branch below, or the cancellation handler above) actually
                // unblocks. Structured concurrency will not let this scope return
                // until that loser has actually finished, so neither a stray timer
                // nor a still-reading thread outlives the call.
                defer { group.cancelAll() }
                guard let first = try await group.next() else { throw Failure.noResult }
                switch first {
                case let .finished(result):
                    return result
                case .timedOut:
                    child.terminate()
                    throw Failure.timedOut
                }
            }
        } onCancel: {
            child.terminate()
        }
    }

    private enum Race: Sendable {
        case finished(Output)
        case timedOut
    }

    private static func runToCompletion(_ child: Child) async throws -> Output {
        try await withCheckedThrowingContinuation { continuation in
            Thread {
                do {
                    continuation.resume(returning: try child.runToCompletion())
                } catch {
                    continuation.resume(throwing: Failure.didNotStart(error.localizedDescription))
                }
            }.start()
        }
    }
}

private struct Output: Sendable {
    let stdout: Data
    let stderr: Data
    let exitCode: Int32
}

/// One spawn of the binary, wrapping the one `Process`/`Pipe` pair only this
/// type ever touches.
///
/// `@unchecked Sendable`: `terminate()` runs from a different task than
/// `runToCompletion()`'s thread; `lock` is what makes the two safe together,
/// not any thread-safety of `Process` itself.
private final class Child: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe: Pipe?
    private var stderr = Data()
    /// True only once `process.run()` has returned. Apple documents
    /// `terminate()` on an unlaunched process as undefined, and `terminate()`
    /// can arrive before the spawn thread has even reached `run()` -- an
    /// immediate cancellation races the spawn itself.
    private var launched = false
    private var terminateRequested = false

    init(binaryPath: String, arguments: [String], environment: [String: String]?, capturesStderr: Bool) {
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardOutput = stdoutPipe
        stderrPipe = capturesStderr ? Pipe() : nil
        process.standardError = stderrPipe ?? FileHandle.nullDevice
    }

    /// Reads stdout to EOF before waiting: a verb that writes more than the
    /// pipe's buffer would deadlock a `waitUntilExit()` called first, since
    /// the child would block on a write nothing is draining. stderr drains on
    /// a thread of its own for the same reason.
    func runToCompletion() throws -> Output {
        try process.run()
        lock.lock()
        launched = true
        let requestedBeforeLaunch = terminateRequested
        lock.unlock()
        if requestedBeforeLaunch { process.terminate() }

        let stderrDrained = DispatchGroup()
        if let stderrPipe {
            stderrDrained.enter()
            Thread { [self] in
                let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                lock.withLock { stderr = data }
                stderrDrained.leave()
            }.start()
        }
        let stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        stderrDrained.wait()
        return Output(stdout: stdout, stderr: lock.withLock { stderr }, exitCode: process.terminationStatus)
    }

    /// Before launch this only records the request: the real
    /// `Process.terminate()` call is deferred to the moment `runToCompletion`
    /// observes `launched`, the earliest point calling it is defined.
    func terminate() {
        lock.lock()
        defer { lock.unlock() }
        guard launched else {
            terminateRequested = true
            return
        }
        process.terminate()
    }
}
