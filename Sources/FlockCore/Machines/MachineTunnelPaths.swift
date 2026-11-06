import CryptoKit
import Foundation

/// Local socket paths for one machine's ssh tunnel. Unix socket paths top out
/// at 104 bytes on macOS, so these stay short and under /tmp.
public struct MachineTunnelPaths: Equatable, Sendable {
    public let directory: String
    public let apiSocket: String
    public let clientSocket: String

    public init(uid: uid_t, bundleTag: String, machineID: String) {
        directory = "\(Self.root(uid: uid))/\(bundleTag)-\(machineID.prefix(12))"
        apiSocket = "\(directory)/herdr.sock"
        clientSocket = "\(directory)/herdr-client.sock"
    }

    public static func root(uid: uid_t) -> String {
        "/tmp/flock-\(uid)"
    }

    /// Entries of `root` that are this app's tunnel directories; another
    /// app's are its own to clear.
    public static func staleEntries(_ entries: [String], bundleTag: String) -> [String] {
        let prefix = "\(bundleTag)-"
        return entries.filter { $0.hasPrefix(prefix) && $0.count > prefix.count }
    }

    /// Keeps Flock and Flock Dev tunnels apart.
    public static func bundleTag(for bundleID: String) -> String {
        if bundleID == "dev.mattstack.Flock" { return "rel" }
        if bundleID.hasSuffix(".dev") { return "dev" }
        let digest = SHA256.hash(data: Data(bundleID.utf8))
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }
}
