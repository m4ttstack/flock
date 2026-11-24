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

    public mutating func set(_ path: String, as number: Int, in conversation: String, now: Date) {
        var entry = conversations[conversation] ?? Conversation(updated: now, images: [:])
        entry.images[number] = path
        entry.updated = now
        conversations[conversation] = entry
    }

    /// Forgets conversations no image has joined in `maximumAge`, and returns
    /// the paths nothing left points at.
    public mutating func prune(now: Date) -> Set<String> {
        let cutoff = now.addingTimeInterval(-Self.maximumAge)
        let stale = conversations.filter { $0.value.updated < cutoff }
        guard !stale.isEmpty else { return [] }
        for key in stale.keys { conversations[key] = nil }
        let live = Set(conversations.values.flatMap { $0.images.values })
        return Set(stale.values.flatMap { $0.images.values }).subtracting(live)
    }
}
