import Foundation

/// rt's `chat.autoSignIn` signs a new agent session in from a startup hook,
/// after the pane's first status read has already cached it as signed out.
/// Flock reads the setting for the agent's folder and, when it is on, asks
/// again until the sign-in lands or the window below runs out.
public enum ChatAutoSignIn {
    public static let interval: Duration = .seconds(1)
    public static let attempts = 30

    public static let agent = "claude"

    public static func settingArguments(folder: String) -> [String] {
        ["settings", "get", "chat.autoSignIn", "--repo", folder, "--json"]
    }

    /// Anything but a decoded `true` is off: an rt too old to know the key,
    /// a folder outside every repo rt knows, or a failed call.
    public static func isOn(stdout: Data, exitCode: Int32) -> Bool {
        guard exitCode == 0, let reply = try? JSONDecoder().decode(SettingReply.self, from: stdout) else { return false }
        return reply.value == true
    }

    /// Only an agent that appears while Flock watches the pane: one already
    /// running when Flock first sees the pane is past its startup hook.
    public static func shouldFollow(previousAgent: String?, agent: String?) -> Bool {
        previousAgent == nil && agent == Self.agent
    }

    private struct SettingReply: Decodable {
        let value: Bool?
    }
}
