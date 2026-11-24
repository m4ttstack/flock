import Foundation

/// Which file each conversation's images came from. A conversation's id is
/// the key because it outlives a herdr handoff and an app relaunch, and a
/// fresh conversation numbers its images from the start again.
public struct PastedImageIndex: Codable, Equatable, Sendable {
    public static let maximumAge: TimeInterval = 14 * 24 * 60 * 60

    private struct Conversation: Codable, Equatable {
        var updated: Date
        var images: [Int: String]
        /// Dropped files. Optional so an index from before there were any
        /// still reads.
        var attachments: [Int: String]?
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

    public func files(for conversation: String) -> [Int: String] {
        conversations[conversation]?.attachments ?? [:]
    }

    public mutating func set(_ path: String, asFile number: Int, in conversation: String, now: Date) {
        var entry = conversations[conversation] ?? Conversation(updated: now, images: [:])
        entry.attachments = (entry.attachments ?? [:]).merging([number: path]) { $1 }
        entry.updated = now
        conversations[conversation] = entry
    }

    public mutating func set(_ path: String, as number: Int, in conversation: String, now: Date) {
        var entry = conversations[conversation] ?? Conversation(updated: now, images: [:])
        entry.images[number] = path
        entry.updated = now
        conversations[conversation] = entry
    }

    /// Notes that a conversation is still in use. False for one with no
    /// images, which there is nothing to keep for.
    public mutating func touch(_ conversation: String, now: Date) -> Bool {
        guard conversations[conversation] != nil else { return false }
        conversations[conversation]?.updated = now
        return true
    }

    public var livePaths: Set<String> {
        Set(conversations.values.flatMap { $0.images.values })
    }

    /// Forgets conversations not used in `maximumAge`.
    public mutating func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.maximumAge)
        conversations = conversations.filter { $0.value.updated >= cutoff }
    }
}
