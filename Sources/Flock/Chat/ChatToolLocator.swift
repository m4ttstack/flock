import FlockCore
import Foundation
import os

/// Where the herdr-chat binary is, or whether it exists on this machine at
/// all -- decided from paths, never from spawning it and reading an error.
///
/// First runnable of: `FLOCK_HERDR_CHAT_BIN`; Flock Dev's `FlockHerdrChatPath`,
/// the mattstack checkout's own build that `Scripts/dev-build.sh` writes in;
/// the copy `Scripts/build-herdr-chat.sh` puts in the bundle's resources.
/// Nothing installed inside herdr counts: flock ships its own.
enum ChatToolLocator {
    static let log = Logger(subsystem: "dev.mattstack.flock", category: "chat")

    static let bundledResourceName = "herdr-chat"

    /// Resolved on first read and then fixed for the process's life, the way
    /// `ToolPath.resolved` is. The path is fixed, not the binary: every verb
    /// spawns it afresh, so a rebuild in the dev checkout lands on the next call.
    static let binaryPath: String? = resolve(
        environmentOverride: ProcessInfo.processInfo.environment["FLOCK_HERDR_CHAT_BIN"],
        devPath: devPath(in: Bundle.main.infoDictionary),
        bundledPath: Bundle.main.resourceURL?.appendingPathComponent(bundledResourceName).path
    )

    /// `ChatStore`'s probe: awaits the first read of `binaryPath` from a
    /// detached task, so the caller -- however soon after launch it awaits
    /// this -- is never the thread that pays for the filesystem checks.
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

    static func resolve(environmentOverride: String?, devPath: String?, bundledPath: String?) -> String? {
        let resolved = ChatAvailability.resolve(
            [environmentOverride, devPath, bundledPath], isRunnable: isExecutableFile
        )
        let source = switch resolved {
        case nil: "none"
        case environmentOverride: "override"
        case devPath: "dev"
        default: "bundled"
        }
        log.log(
            "chat tool override=\(environmentOverride != nil, privacy: .public) dev=\(devPath != nil, privacy: .public) resolved=\(source, privacy: .public)"
        )
        return resolved
    }

    /// nil unless a build set it: the release app's plist has no such key,
    /// and a build that never passed `FLOCK_HERDR_CHAT_PATH` leaves it empty.
    static func devPath(in info: [String: Any]?) -> String? {
        guard let path = info?["FlockHerdrChatPath"] as? String, !path.isEmpty, !path.hasPrefix("$(") else {
            return nil
        }
        return path
    }

    /// false for anything that is not a plain, executable file: a directory,
    /// or a checkout that has not built yet.
    private static func isExecutableFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }
}
