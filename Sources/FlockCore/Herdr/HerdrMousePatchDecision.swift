import Foundation

/// The states the herdr settings row can be in. Detection answers separate
/// questions -- verb presence, version, backup presence, which revision of
/// flock's patch -- and they must not collapse into one, because a binary
/// that carries the verbs with no flock backup means upstream adopted the
/// change, which is a different state from flock's own patch even though both
/// show the same verbs.
public enum HerdrMousePatchRowState: Equatable, Sendable {
    /// herdr itself reports mouse events; there is no flock backup beside it,
    /// so nothing here came from this feature.
    case supportedByHerdr
    /// flock's patch is the reason the verbs are present. `backupPath` is
    /// where the original sits, and is what Revert restores.
    case installed(backupPath: String)
    /// flock's patch is installed, but an earlier revision of it: `release`
    /// names the newer one this flock can put in its place.
    case outdated(installPath: String, version: String, release: String, backupPath: String)
    /// Not yet patched, but this herdr is a version the catalogue covers and
    /// the location is writable.
    case patchable(installPath: String, version: String)
    /// The install location is not writable by this user. Never crossed with
    /// an admin prompt: a herdr flock cannot write is left alone.
    case notWritable(installPath: String)
    /// No catalogue entry for this herdr: older than the first patch, or newer than this flock knows.
    case unsupportedVersion

    /// flock's patch is on this herdr, current or not.
    public var hasFlockPatch: Bool {
        switch self {
        case .installed, .outdated: true
        case .supportedByHerdr, .patchable, .notWritable, .unsupportedVersion: false
        }
    }
}

/// The pure matrix behind the row: given what detection found, which state
/// results. No filesystem, no herdr, nothing to mock -- this is the feature
/// the design calls out as what actually needs testing.
public enum HerdrMousePatchDecision {
    /// `newerRelease` is the release name of a newer revision when the
    /// installed binary is a superseded one, nil otherwise.
    public static func decide(
        hasVerbs: Bool,
        hasBackup: Bool,
        version: String?,
        isWritable: Bool,
        installPath: String,
        backupPath: String,
        newerRelease: String? = nil
    ) -> HerdrMousePatchRowState {
        if hasVerbs {
            guard hasBackup else { return .supportedByHerdr }
            if let newerRelease, let version, isWritable {
                return .outdated(installPath: installPath, version: version, release: newerRelease, backupPath: backupPath)
            }
            return .installed(backupPath: backupPath)
        }
        if !isWritable {
            return .notWritable(installPath: installPath)
        }
        guard let version else {
            return .unsupportedVersion
        }
        return .patchable(installPath: installPath, version: version)
    }
}
