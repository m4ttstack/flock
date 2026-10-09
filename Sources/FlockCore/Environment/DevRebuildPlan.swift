import Foundation

/// The rules behind Flock Dev's Rebuild Flock Dev command.
public enum DevRebuildPlan {
    public static let branch = "main"
    public static let firstExpectedDuration: TimeInterval = 120
    /// The bar never reads done before the build is: the estimate is only the
    /// last build's length.
    public static let progressCeiling = 0.95

    /// `Scripts/dev-build.sh` writes Flock Dev to `<checkout>/build/dev/`, and
    /// worktree builds point their output there too.
    public static func checkout(forBundle path: String) -> String? {
        let bundle = URL(fileURLWithPath: path).standardized
        let dev = bundle.deletingLastPathComponent()
        let build = dev.deletingLastPathComponent()
        guard dev.lastPathComponent == "dev", build.lastPathComponent == "build" else { return nil }
        return build.deletingLastPathComponent().path
    }

    /// nil when the checkout may be built.
    public static func refusal(branch current: String?) -> String? {
        guard let current else { return "Flock Dev couldn't read the checkout's branch." }
        return current == branch ? nil : "Flock Dev builds from \(branch), and the checkout is on \(current)."
    }

    public static func expectedDuration(last: TimeInterval?) -> TimeInterval {
        last ?? firstExpectedDuration
    }

    public static func progress(elapsed: TimeInterval, expected: TimeInterval) -> Double {
        guard expected > 0 else { return progressCeiling }
        return min(progressCeiling, max(0, elapsed / expected))
    }
}
