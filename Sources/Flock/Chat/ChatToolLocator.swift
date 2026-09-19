import FlockCore
import Foundation
import os

/// Where the herdr-chat binary is, or whether it exists on this machine at
/// all -- decided from paths, never from spawning it and reading an error.
///
/// The plugin installer writes a build under
/// `~/.config/herdr/plugins/<install-kind>/<plugin-slug>-<hash>/target/release/`,
/// `<install-kind>` being "config" or "github" and the hash distinguishing
/// rebuilds of the same plugin id (`src/api/schema/plugins.rs` in the herdr
/// repo, `plugin_managed_path_component`). Two wildcards, one per segment.
enum ChatToolLocator {
    static let log = Logger(subsystem: "dev.mattstack.flock", category: "chat")

    /// Resolved on first read and then fixed for the process's life, the way
    /// `ToolPath.resolved` is.
    static let binaryPath: String? = resolve(
        environmentOverride: ProcessInfo.processInfo.environment["FLOCK_HERDR_CHAT_BIN"],
        pluginsDirectory: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/herdr/plugins", isDirectory: true)
    )

    /// `ChatStore`'s probe: awaits the first read of `binaryPath` from a
    /// detached task, so the caller -- however soon after launch it awaits
    /// this -- is never the thread that pays for the filesystem walk.
    static func probeBinaryPath() async -> String? {
        await Task.detached(priority: .userInitiated) { binaryPath }.value
    }

    /// herdr-chat shells out to `rt` for every verb it runs, so `rt` missing
    /// is exactly as absent as the plugin binary itself -- checked here,
    /// off the main actor, rather than inferred later from a failed call.
    static func probeRTBinaryFound() async -> Bool {
        await Task.detached(priority: .userInitiated) { ToolPath.resolve("rt") != nil }.value
    }

    /// Open Viewer alone depends on `deck`; checked the same way as `rt`,
    /// but its absence disables only that one row.
    static func probeDeckBinaryFound() async -> Bool {
        await Task.detached(priority: .userInitiated) { ToolPath.resolve("deck") != nil }.value
    }

    /// `pluginsDirectory` is a parameter rather than always the real
    /// `~/.config/herdr/plugins` so a test can point it at a temporary tree.
    static func resolve(environmentOverride: String?, pluginsDirectory: URL) -> String? {
        let candidates = installCandidates(under: pluginsDirectory)
        let validatedOverride = validated(environmentOverride)
        let resolved = ChatAvailability.resolve(environmentOverride: validatedOverride, candidates: candidates)
        log.log(
            "chat tool override=\(environmentOverride != nil, privacy: .public) overrideValid=\(validatedOverride != nil, privacy: .public) candidates=\(candidates.count, privacy: .public) resolved=\(resolved != nil, privacy: .public)"
        )
        return resolved
    }

    /// An override the caller asked for but that does not exist, or exists
    /// but is not executable, is worth exactly as much as no override: falling
    /// through to a real install beats reporting chat present at a dead path.
    private static func validated(_ override: String?) -> String? {
        guard let override, !override.isEmpty else { return nil }
        return executableModificationDate(URL(fileURLWithPath: override)) != nil ? override : nil
    }

    private static func installCandidates(under pluginsDirectory: URL) -> [(path: String, modified: TimeInterval)] {
        let manager = FileManager.default
        guard let installKinds = try? manager.contentsOfDirectory(at: pluginsDirectory, includingPropertiesForKeys: nil)
        else { return [] }

        var candidates: [(path: String, modified: TimeInterval)] = []
        for installKind in installKinds {
            guard let plugins = try? manager.contentsOfDirectory(at: installKind, includingPropertiesForKeys: nil)
            else { continue }
            for plugin in plugins where plugin.lastPathComponent.hasPrefix("m4ttstack.chat") {
                let binary = plugin.appendingPathComponent("target/release/herdr-chat")
                guard let modified = executableModificationDate(binary) else { continue }
                candidates.append((binary.path, modified))
            }
        }
        return candidates
    }

    /// nil for anything that is not a plain, executable file: a directory
    /// misnamed to match the glob, or a checkout that has not built yet.
    private static func executableModificationDate(_ url: URL) -> TimeInterval? {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard
            manager.fileExists(atPath: url.path, isDirectory: &isDirectory),
            !isDirectory.boolValue,
            manager.isExecutableFile(atPath: url.path),
            let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        else { return nil }
        return modified.timeIntervalSince1970
    }
}
