import FlockCore
import Foundation

/// What every later chat view and store runs a verb against, so each is
/// testable with a fake that returns canned JSON instead of touching a real
/// process.
public protocol ChatRunning: Sendable {
    func run(_ verb: ChatVerb) async throws -> (stdout: Data, exitCode: Int32)
}

/// Runs `herdr-chat` as a child process under a hard deadline.
///
/// `Process` is not `Sendable`, so every touch of it lives inside `Child`,
/// which this type hands to a dedicated thread and never opens itself: the
/// caller's actor only ever awaits a continuation, so a `MainActor` caller is
/// never the thread that blocks on the child's exit.
public struct ChatRunner: ChatRunning {
    public static let deadline: Duration = .seconds(5)

    private let binaryPath: String
    private let deadline: Duration

    public init(binaryPath: String, deadline: Duration = ChatRunner.deadline) {
        self.binaryPath = binaryPath
        self.deadline = deadline
    }

    public func run(_ verb: ChatVerb) async throws -> (stdout: Data, exitCode: Int32) {
        try await runRaw(verb.arguments)
    }

    public func runRaw(_ arguments: [String]) async throws -> (stdout: Data, exitCode: Int32) {
        let child = Child(binaryPath: binaryPath, arguments: arguments)

        return try await withThrowingTaskGroup(of: Race.self) { group in
            group.addTask { .finished(try await Self.runToCompletion(child)) }
            group.addTask {
                try await Task.sleep(for: self.deadline)
                return .timedOut
            }
            // Whichever of the two finishes first decides the call; `cancelAll`
            // then reaches for the loser -- the sleep, cancelled instantly, or
            // the reader, which only the `.timedOut` branch's `terminate()`
            // below actually unblocks. Structured concurrency will not let this
            // scope return until that loser has actually finished, so neither a
            // stray timer nor a still-reading thread outlives the call.
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw ChatFailure(message: "chat call produced no result")
            }
            switch first {
            case let .finished(result):
                return result
            case .timedOut:
                child.terminate()
                throw ChatFailure(message: "chat call to \(binaryPath) exceeded its \(deadline) deadline")
            }
        }
    }

    private enum Race: Sendable {
        case finished((stdout: Data, exitCode: Int32))
        case timedOut
    }

    private static func runToCompletion(_ child: Child) async throws -> (stdout: Data, exitCode: Int32) {
        try await withCheckedThrowingContinuation { continuation in
            Thread {
                do {
                    continuation.resume(returning: try child.runToCompletion())
                } catch {
                    continuation.resume(throwing: ChatFailure(message: "chat failed to start: \(error.localizedDescription)"))
                }
            }.start()
        }
    }
}

/// One spawn of the binary, wrapping the one `Process`/`Pipe` pair only this
/// type ever touches.
///
/// `@unchecked Sendable`: `terminate()` is called from a different task than
/// `runToCompletion()`'s thread, but `Process.terminate()` is safe to call
/// concurrently with `waitUntilExit()` -- it only ever posts a signal.
private final class Child: @unchecked Sendable {
    private let process = Process()
    private let stdoutPipe = Pipe()

    init(binaryPath: String, arguments: [String]) {
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
    }

    /// Reads stdout to EOF before waiting: a verb that writes more than the
    /// pipe's buffer would deadlock a `waitUntilExit()` called first, since
    /// the child would block on a write nothing is draining.
    func runToCompletion() throws -> (stdout: Data, exitCode: Int32) {
        try process.run()
        let stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (stdout, process.terminationStatus)
    }

    func terminate() {
        process.terminate()
    }
}
