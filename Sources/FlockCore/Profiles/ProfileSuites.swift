import CryptoKit
import Foundation

/// UserDefaults suite names. The default profile on the default socket keeps
/// using the standard defaults, so existing settings carry over untouched.
public enum ProfileSuites {
    public static func preferencesSuiteName(bundleID: String, profileID: String) -> String? {
        profileID == FlockProfile.defaultID ? nil : "\(bundleID).profile.\(profileID)"
    }

    /// Both paths arrive normalized.
    public static func serverSuiteName(bundleID: String, profileID: String, socketPath: String, defaultSocketPath: String) -> String? {
        if profileID == FlockProfile.defaultID && socketPath == defaultSocketPath { return nil }
        return "\(bundleID).profile.\(profileID).server.\(socketKey(socketPath))"
    }

    public static func overrideSuiteName(bundleID: String) -> String {
        "\(bundleID).override"
    }

    public static func socketKey(_ normalizedSocketPath: String) -> String {
        let digest = SHA256.hash(data: Data(normalizedSocketPath.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(12).description
    }

    public static func allSuiteNames(for profile: FlockProfile, bundleID: String, defaultSocketPath: String) -> [String] {
        let preferences = preferencesSuiteName(bundleID: bundleID, profileID: profile.id).map { [$0] } ?? []
        let servers = profile.knownSockets.compactMap {
            serverSuiteName(bundleID: bundleID, profileID: profile.id, socketPath: $0, defaultSocketPath: defaultSocketPath)
        }
        return preferences + servers
    }
}
