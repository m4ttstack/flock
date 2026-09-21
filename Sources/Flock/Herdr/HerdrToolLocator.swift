import Foundation

/// Whether herdr itself -- not the daemon, not a socket -- is on this Mac at
/// all. `ToolPath` owns the PATH; this only asks it off the main actor, the
/// way `ChatToolLocator.probeRTBinaryFound` asks the same question for `rt`.
enum HerdrToolLocator {
    static func probeBinaryFound() async -> Bool {
        await Task.detached(priority: .userInitiated) { ToolPath.resolve("herdr") != nil }.value
    }
}
