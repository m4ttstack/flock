import Foundation

/// A named set of preferences and a herdr server to talk to. A nil
/// `socketPath` means herdr's default socket; `knownSockets` holds normalized
/// paths, each once, in first-use order.
public struct FlockProfile: Codable, Equatable, Sendable, Identifiable {
    public static let defaultID = "default"

    public let id: String
    public var name: String
    public var socketPath: String?
    public var knownSockets: [String]

    public init(id: String, name: String, socketPath: String?, knownSockets: [String]) {
        self.id = id
        self.name = name
        self.socketPath = socketPath
        self.knownSockets = knownSockets
    }
}
