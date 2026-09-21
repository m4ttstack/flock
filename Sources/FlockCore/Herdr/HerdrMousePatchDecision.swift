import Foundation

/// The four states the herdr settings row can be in. Detection answers three
/// separate questions -- verb presence, version, backup presence -- and they
/// must not collapse into one, because a binary that carries the verbs with
/// no flock backup means upstream adopted the change, which is a different
/// state from flock's own patch even though both show the same verbs.
public enum HerdrMousePatchRowState: Equatable, Sendable {
    /// herdr itself reports mouse events; there is no flock backup beside it,
    /// so nothing here came from this feature.
    case supportedByHerdr
    /// flock's patch is the reason the verbs are present. `backupPath` is
    /// where the original sits, and is what Revert restores.
    case installed(backupPath: String)
    /// Not yet patched, but this herdr is the one version this build covers,
    /// the location is writable, and a prebuilt artifact is on hand.
    case patchable(installPath: String)
    /// This build carries no prebuilt patch for the version installed, even
    /// though it would otherwise be covered -- the ordinary state on a fresh
    /// clone, since the artifact is gitignored.
    case artifactUnavailable(installPath: String)
    /// The install location is not writable by this user. Never crossed with
    /// an admin prompt: a herdr flock cannot write is left alone.
    case notWritable(installPath: String)
    /// This herdr is not the one version this build's patch was made for.
    case unsupportedVersion
}

/// The pure matrix behind the row: given what detection found, which state
/// results. No filesystem, no herdr, nothing to mock -- this is the feature
/// the design calls out as what actually needs testing.
public enum HerdrMousePatchDecision {
    public static func decide(
        hasVerbs: Bool,
        hasBackup: Bool,
        versionSupported: Bool,
        isWritable: Bool,
        artifactAvailable: Bool,
        installPath: String,
        backupPath: String
    ) -> HerdrMousePatchRowState {
        if hasVerbs {
            return hasBackup ? .installed(backupPath: backupPath) : .supportedByHerdr
        }
        if !isWritable {
            return .notWritable(installPath: installPath)
        }
        if !versionSupported {
            return .unsupportedVersion
        }
        if !artifactAvailable {
            return .artifactUnavailable(installPath: installPath)
        }
        return .patchable(installPath: installPath)
    }
}
