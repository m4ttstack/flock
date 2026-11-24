import Foundation

/// Which file each conversation's images came from. A conversation's id is
/// the key because it outlives a herdr handoff and an app relaunch, and a
/// fresh conversation numbers its images from the start again.
public struct PastedImageIndex: Codable, Equatable, Sendable {
    public static let maximumAge: TimeInterval = 14 * 24 * 60 * 60

    private struct Conversation: Codable, Equatable {
        var updated: Date
        var images: [Int: String]
    }

    private var conversations: [String: Conversation] = [:]

    public init() {}

    public init(from decoder: Decoder) throws {
        conversations = try decoder.singleValueContainer().decode([String: Conversation].self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(conversations)
    }

    public func images(for conversation: String) -> [Int: String] {
        conversations[conversation]?.images ?? [:]
    }

    /// Returns the path this replaced, where nothing else points at it.
    public mutating func set(_ path: String, as number: Int, in conversation: String, now: Date) -> String? {
        var entry = conversations[conversation] ?? Conversation(updated: now, images: [:])
        let replaced = entry.images.updateValue(path, forKey: number)
        entry.updated = now
        conversations[conversation] = entry
        return replaced.flatMap { livePaths.contains($0) ? nil : $0 }
    }

    /// Notes that a conversation is still in use. False for one with no
    /// images, which there is nothing to keep for.
    public mutating func touch(_ conversation: String, now: Date) -> Bool {
        guard conversations[conversation] != nil else { return false }
        conversations[conversation]?.updated = now
        return true
    }

    private var livePaths: Set<String> {
        Set(conversations.values.flatMap { $0.images.values })
    }

    /// Forgets conversations not used in `maximumAge`, and returns the paths
    /// nothing left points at.
    public mutating func prune(now: Date) -> Set<String> {
        let cutoff = now.addingTimeInterval(-Self.maximumAge)
        let stale = conversations.filter { $0.value.updated < cutoff }
        guard !stale.isEmpty else { return [] }
        for key in stale.keys { conversations[key] = nil }
        return Set(stale.values.flatMap { $0.images.values }).subtracting(livePaths)
    }
}
