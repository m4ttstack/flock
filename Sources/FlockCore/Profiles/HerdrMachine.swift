import Foundation

/// A machine herdr knows about, reached through an ssh tunnel to its server.
public struct HerdrMachine: Codable, Equatable, Sendable {
    public let id: String
    public var label: String
    public var target: String
    public var session: String

    public init(id: String, label: String, target: String, session: String) {
        self.id = id
        self.label = label
        self.target = target
        self.session = session
    }
}

/// Reads `herdr machine list` output.
public enum HerdrMachineList {
    private struct Entry: Decodable {
        let id: String
        let label: String
        let target: String
        let session: String?
        let enabled: Bool
    }

    /// Enabled entries only; nil when the output is not a JSON array of machines.
    public static func parse(_ stdout: Data) -> [HerdrMachine]? {
        guard let entries = try? JSONDecoder().decode([Entry].self, from: stdout) else { return nil }
        return entries.filter(\.enabled).map {
            HerdrMachine(id: $0.id, label: $0.label, target: $0.target, session: $0.session ?? "default")
        }
    }
}
