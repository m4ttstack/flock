import Foundation

/// What a machine profile's window says while its ssh forward or the remote
/// herdr is not serving panes. The tunnel's state wins over the store's,
/// except once the forward is up: then only the store knows whether herdr
/// answers.
public enum MachineConnectionCopy {
    public static func banner(label: String, tunnel: MachineTunnelState, store: ConnectionState) -> String? {
        switch tunnel {
        case .stopped:
            return nil
        case .connecting:
            return connecting(label)
        case .unreachable(let reason):
            return unreachable(label: label, reason: reason)
        case .noServer:
            return notRunning(label)
        case .up:
            switch store {
            case .live, .unsupported: return nil
            case .connecting: return connecting(label)
            case .reconnecting, .notRunning: return notRunning(label)
            }
        }
    }

    public static func versionWarning(label: String, local: String?, remote: String?) -> String? {
        guard let local, let remote, local != remote else { return nil }
        return "\(label) runs herdr \(remote) and this Mac has \(local). Panes may misbehave until they match."
    }

    public static func removed(label: String) -> String {
        "\(label) is no longer a saved herdr machine."
    }

    private static func connecting(_ label: String) -> String {
        "Connecting to \(label)\u{2026}"
    }

    private static func notRunning(_ label: String) -> String {
        "herdr isn't running on \(label)."
    }

    private static func unreachable(label: String, reason: String) -> String {
        let reason = reason.hasSuffix(".") || reason.hasSuffix("!") ? reason : reason + "."
        let lowered = reason.lowercased()
        let head = "Can't reach \(label). \(reason)"
        if lowered.contains("host key verification") || lowered.contains("remote host identification has changed") {
            return "\(head) Run ssh \(label) once in Terminal, then add its host key to known_hosts."
        }
        if lowered.contains("permission denied") {
            return "\(head) If your key has a passphrase, run ssh-add, then check that ssh \(label) works."
        }
        return head
    }
}
