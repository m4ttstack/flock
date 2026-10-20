import Foundation

public struct HerdrSessionEntry: Equatable, Sendable {
    public let name: String
    public let isRunning: Bool
    public let socketPath: String
    public let isDefault: Bool

    public init(name: String, isRunning: Bool, socketPath: String, isDefault: Bool) {
        self.name = name
        self.isRunning = isRunning
        self.socketPath = socketPath
        self.isDefault = isDefault
    }
}

/// The answer of `herdr session list --json`.
public enum HerdrSessionList {
    private struct Payload: Decodable {
        struct Session: Decodable {
            let name: String
            let running: Bool
            let socketPath: String
            let isDefault: Bool

            enum CodingKeys: String, CodingKey {
                case name, running
                case socketPath = "socket_path"
                case isDefault = "default"
            }
        }
        let sessions: [Session]
    }

    /// Nil when the output is not that list.
    public static func parse(_ stdout: Data) -> [HerdrSessionEntry]? {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: stdout) else { return nil }
        return payload.sessions.map {
            HerdrSessionEntry(name: $0.name, isRunning: $0.running, socketPath: $0.socketPath, isDefault: $0.isDefault)
        }
    }
}
