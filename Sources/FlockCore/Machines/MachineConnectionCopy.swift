import Foundation

/// What a machine profile's window says while its ssh forward or the remote
/// herdr is not serving panes. The tunnel's state wins over the store's,
/// except once the forward is up: then only the store knows whether herdr
/// answers. `tunnelUpGraceActive` covers the store's first attempts after the
/// forward comes up, which may still be failing on the wait it began before.
public enum MachineConnectionCopy {
    public static func banner(
        label: String, tunnel: MachineTunnelState, store: ConnectionState, tunnelUpGraceActive: Bool = false
    ) -> String? {
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
            case .reconnecting, .notRunning: return tunnelUpGraceActive ? connecting(label) : notRunning(label)
            }
        }
    }

    /// A removed machine outranks the connection, which outranks a version
    /// mismatch; the mismatch shows only once panes are being served.
    public static func notice(
        label: String, tunnel: MachineTunnelState, store: ConnectionState,
        local: String?, remote: String?, removed: Bool, tunnelUpGraceActive: Bool = false
    ) -> String? {
        if removed { return Self.removed(label: label) }
        if let banner = banner(label: label, tunnel: tunnel, store: store, tunnelUpGraceActive: tunnelUpGraceActive) {
            return banner
        }
        guard store == .live else { return nil }
        return versionWarning(label: label, local: local, remote: remote)
    }

    public static func versionWarning(label: String, local: String?, remote: String?) -> String? {
        guard let local, let remote, local != remote else { return nil }
        return "\(label) runs herdr \(remote) and this Mac has \(local). Panes may misbehave until they match."
    }

    /// The first sentence of a banner, for where the whole of it does not fit.
    public static func short(_ full: String) -> String {
        guard let stop = full.range(of: ". ") else { return full }
        return String(full[..<stop.upperBound]).trimmingCharacters(in: .whitespaces)
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
