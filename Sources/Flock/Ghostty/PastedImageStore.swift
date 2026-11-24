import Foundation
import os

private let pastedImageLog = Logger(subsystem: "dev.mattstack.flock", category: "pasted-images")

/// SPIKE: which file each conversation's `[Image #N]` came from, kept across
/// launches. A conversation's id is the key because it alone outlives a herdr
/// handoff and changes when the program starts numbering over.
///
/// Flock's own staged clipboard images are copied here, since staging reaps
/// them after a day; any other file is only pointed at.
@MainActor
final class PastedImageStore {
    static let shared = PastedImageStore()

    private struct Conversation: Codable {
        var updated: Date
        var images: [Int: String]
    }

    private static let maximumAge: TimeInterval = 14 * 24 * 60 * 60

    private let directory: URL
    private var conversations: [String: Conversation] = [:]

    private var index: URL { directory.appendingPathComponent("index.json") }

    private init() {
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "dev.mattstack.Flock", isDirectory: true)
            .appendingPathComponent("pasted-images", isDirectory: true)
        guard let data = try? Data(contentsOf: index) else { return }
        do {
            conversations = try JSONDecoder().decode([String: Conversation].self, from: data)
        } catch {
            pastedImageLog.warning("cannot read the pasted image index: \(error.localizedDescription, privacy: .public)")
        }
        prune()
    }

    func images(for conversation: String) -> [Int: String] {
        conversations[conversation]?.images ?? [:]
    }

    /// The path the image is kept at from here on.
    @discardableResult
    func keep(_ path: String, as number: Int, in conversation: String) -> String {
        guard ensureDirectory() else { return path }
        let kept = isStaged(path) ? copy(path) ?? path : path
        var entry = conversations[conversation] ?? Conversation(updated: Date(), images: [:])
        entry.images[number] = kept
        entry.updated = Date()
        conversations[conversation] = entry
        save()
        return kept
    }

    private func isStaged(_ path: String) -> Bool {
        path.hasPrefix(ClipboardImageStaging.directory.path + "/")
    }

    private func copy(_ path: String) -> String? {
        let source = URL(fileURLWithPath: path)
        let target = directory.appendingPathComponent(source.lastPathComponent)
        if FileManager.default.fileExists(atPath: target.path) { return target.path }
        do {
            try FileManager.default.copyItem(at: source, to: target)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            return target.path
        } catch {
            pastedImageLog.warning("cannot keep a pasted image: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func ensureDirectory() -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            return true
        } catch {
            pastedImageLog.warning("pasted images cannot be kept: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func save() {
        do {
            try JSONEncoder().encode(conversations).write(to: index, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: index.path)
        } catch {
            pastedImageLog.warning("cannot save the pasted image index: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Forgets old conversations, and deletes only copies no remaining one
    /// points at: every other path is the user's own file.
    private func prune() {
        let cutoff = Date().addingTimeInterval(-Self.maximumAge)
        let stale = conversations.filter { $0.value.updated < cutoff }
        guard !stale.isEmpty else { return }
        for key in stale.keys { conversations[key] = nil }
        let live = Set(conversations.values.flatMap { $0.images.values })
        for path in stale.values.flatMap({ $0.images.values })
        where path.hasPrefix(directory.path + "/") && !live.contains(path) {
            try? FileManager.default.removeItem(atPath: path)
        }
        save()
    }
}
