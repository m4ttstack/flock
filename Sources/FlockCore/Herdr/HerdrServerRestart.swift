import Foundation

/// When the herdr server has to move to the binary on disk: a Flock restart
/// gives every pane a new per-pane client, but the server keeps running the
/// binary it was started from.
public enum HerdrServerRestart {
    /// Only flock's current patch, only a revision that changes the server,
    /// and only a server seen on another binary. An unknown server is never
    /// pressed to restart.
    public static func isNeeded(
        state: HerdrMousePatchRowState?, patchChangesServer: Bool, server: HerdrServerBinary
    ) -> Bool {
        guard patchChangesServer, case .installed = state else { return false }
        return server == .other
    }

    public static let failedFallback = "herdr's server didn't restart."

    /// herdr's own error line when it printed one: `server live-handoff`
    /// writes a refusal to stderr as `{"error":{"message":...}}`.
    public static func failureReason(output: String) -> String {
        let lines = output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let last = lines.last else { return failedFallback }
        let message = HerdrServerActions.failureMessage(stderr: Data(last.utf8), fallback: last)
        let sentence = message.hasSuffix(".") ? message : message + "."
        return "herdr's server didn't restart: \(sentence)"
    }
}
