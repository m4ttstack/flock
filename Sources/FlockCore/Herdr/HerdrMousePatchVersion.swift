import Foundation

/// Which herdr version a binary is, read from what `herdr --version` prints
/// rather than from the binary's bytes: herdr embeds other version strings
/// (dependency paths, compatibility notes) that a byte scan can mistake for
/// its own.
public enum HerdrMousePatchVersion {
    public static var supported: [String] { HerdrMousePatchCatalog.entries.map(\.version) }

    /// herdr prints exactly `herdr X.Y.Z`; anything else is an unknown
    /// version, never a guess.
    public static func parse(versionOutput: String) -> String? {
        let line = versionOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "herdr "
        guard line.hasPrefix(prefix) else { return nil }
        let version = String(line.dropFirst(prefix.count))
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0 >= "0" && $0 <= "9" } }) else { return nil }
        return version
    }

    /// The catalogued version `versionOutput` names, nil for any other.
    public static func supportedVersion(fromVersionOutput versionOutput: String?) -> String? {
        guard let version = versionOutput.flatMap({ parse(versionOutput: $0) }), supported.contains(version) else {
            return nil
        }
        return version
    }
}
