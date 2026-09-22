import FlockCore
import Foundation

/// What every later chat view and store runs a verb against, so each is
/// testable with a fake that returns canned JSON instead of touching a real
/// process.
public protocol ChatRunning: Sendable {
    func run(_ verb: ChatVerb) async throws -> (stdout: Data, exitCode: Int32)
}

/// Runs `herdr-chat` through `ToolRunner`, reporting every way a call can
/// fail as the `ChatFailure` the chat views already toast.
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
        do {
            return try await ToolRunner(binaryPath: binaryPath, deadline: deadline).run(arguments)
        } catch let failure as ToolRunner.Failure {
            switch failure {
            case .didNotStart(let reason): throw ChatFailure(message: "chat failed to start: \(reason)")
            case .timedOut: throw ChatFailure(message: "chat call to \(binaryPath) exceeded its \(deadline) deadline")
            case .noResult: throw ChatFailure(message: "chat call produced no result")
            }
        }
    }
}
