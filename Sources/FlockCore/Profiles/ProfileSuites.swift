import CryptoKit
import Foundation

/// UserDefaults suite names. The default profile on the default socket keeps
/// using the standard defaults, so existing settings carry over untouched.
public enum ProfileSuites {
    /// Machine profiles share Default's preferences, so they have no suite of their own.
    public static func preferencesSuiteName(bundleID: String, profile: FlockProfile) -> String? {
        profile.id == FlockProfile.defaultID || profile.isMachine ? nil : "\(bundleID).profile.\(profile.id)"
    }

    /// What two Flocks compare to tell whether they hold one herdr session.
    /// Flock and Flock Dev tunnel one machine through different local paths,
    /// so a machine is keyed by its id.
    public static func attachKey(for profile: FlockProfile, socketPath: String) -> String {
        profile.machine.map { "\(FlockClientRecord.machineKeyPrefix)\($0.id)" } ?? socketPath
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
        let preferences = preferencesSuiteName(bundleID: bundleID, profile: profile).map { [$0] } ?? []
        let servers = profile.knownSockets.compactMap {
            serverSuiteName(bundleID: bundleID, profileID: profile.id, socketPath: $0, defaultSocketPath: defaultSocketPath)
        }
        return preferences + servers
    }
}
