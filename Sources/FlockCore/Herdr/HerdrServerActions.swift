import Foundation

/// What Settings offers for one listed herdr session.
public enum HerdrServerAction: Equatable, Sendable {
    case stop
    case delete
    /// Why the session is offered nothing.
    case unavailable(String)
}

public enum HerdrServerActions {
    /// Never the default server, the one this Flock is on, or one another
    /// running Flock holds: stopping any of them is never a cleanup.
    public static func action(
        for entry: HerdrSessionEntry, currentSocket: String, home: String, heldBy: (String) -> String?
    ) -> HerdrServerAction {
        if entry.isDefault { return .unavailable("herdr's own server") }
        let socket = HerdrServerAddress.normalize(entry.socketPath, home: home)
        if socket == HerdrServerAddress.normalize(currentSocket, home: home) {
            return .unavailable("This Flock is on it")
        }
        if let app = heldBy(entry.socketPath) { return .unavailable("Open in \(app)") }
        return entry.isRunning ? .stop : .delete
    }

    /// The confirmation's message. Delete names the profiles whose server
    /// it is, since they keep pointing at it.
    public static func confirmationMessage(
        for entry: HerdrSessionEntry, action: HerdrServerAction, profiles: [(name: String, socketPath: String)], home: String
    ) -> String {
        guard action == .delete else { return "Every pane and agent on it closes. This can't be undone." }
        let socket = HerdrServerAddress.normalize(entry.socketPath, home: home)
        let users = profiles.filter { HerdrServerAddress.normalize($0.socketPath, home: home) == socket }.map(\.name)
        let base = "Its saved workspaces go. This can't be undone."
        return users.isEmpty ? base : base + " Used by \(users.joined(separator: ", "))."
    }

    private struct ErrorPayload: Decodable {
        struct Detail: Decodable { let message: String }
        let error: Detail
    }

    /// herdr writes a session command's error to stderr as
    /// `{"error":{"code":...,"message":...}}`.
    public static func failureMessage(stderr: Data, fallback: String) -> String {
        if let payload = try? JSONDecoder().decode(ErrorPayload.self, from: stderr) {
            let message = payload.error.message.trimmingCharacters(in: .whitespacesAndNewlines)
            if !message.isEmpty { return message }
        }
        let text = String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? fallback : text
    }
}
