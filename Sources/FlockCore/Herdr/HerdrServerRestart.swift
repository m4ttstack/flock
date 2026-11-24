import Foundation

/// When a live handoff of herdr's server is offered, and why one failed. A Flock restart gives every
/// pane a new per-pane client, but the server keeps running the binary it was
/// started from, so only a handoff moves it to the binary on disk.
public enum HerdrServerRestart {
    public static let failedFallback = "herdr's server didn't restart."

    /// What a restart confirmation answers for: the server it would restart,
    /// and the binary it would move it to.
    public struct Offer: Equatable, Sendable {
        public let socketPath: String
        public let binaryPath: String
        public let version: String

        public init(socketPath: String, binaryPath: String, version: String) {
            self.socketPath = socketPath
            self.binaryPath = binaryPath
            self.version = version
        }
    }

    /// `server` answers for `probedSocket` alone, so an answer about one
    /// server offers nothing for another switched to since.
    public static func offer(
        state: HerdrBuildState?, build: HerdrBuildList.Build?, server: HerdrServerBinary, probedSocket: String?,
        currentSocket: String?, binaryPath: String?, version: HerdrBuildVersion?
    ) -> Offer? {
        guard case .current = state, build?.changesServer == true, server == .other,
              let currentSocket, currentSocket == probedSocket, let binaryPath, let version else { return nil }
        return Offer(socketPath: currentSocket, binaryPath: binaryPath, version: version.display)
    }

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
