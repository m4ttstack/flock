import Foundation

public struct ChatFailure: Error, Equatable, Sendable {
    public let message: String
    public init(message: String) { self.message = message }
}

/// One run's answer. The far side prints its failure as `{"error":"..."}` on
/// STDOUT with a non-zero exit, so stdout is read either way and the exit code
/// only says which shape to expect.
public enum ChatOutcome {
    private struct Envelope: Decodable { let error: String }

    public static func decode<T: Decodable>(
        _ type: T.Type, stdout: Data, exitCode: Int32
    ) throws -> T {
        if exitCode != 0 {
            let message = (try? JSONDecoder().decode(Envelope.self, from: stdout))?.error
            throw ChatFailure(message: message ?? "chat exited \(exitCode)")
        }
        return try JSONDecoder().decode(type, from: stdout)
    }
}
