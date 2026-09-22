import Foundation

/// The row's text, one state at a time. Never says "upgrade herdr" or
/// implies the maintainers endorsed this: it states plainly that flock
/// replaces the binary with a build of the same version, keeps a backup, and
/// that it can be undone.
public enum HerdrMousePatchCopy {
    public static let heading = "herdr"
    /// The row's own label, distinct from the section heading above it: the
    /// section names the tool, the row names which of its capabilities.
    public static let rowTitle = "Mouse support"

    /// A path under the user's home as `~/...`, which is how a settings row
    /// can show it on one line.
    public static func displayPath(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    public static func body(for state: HerdrMousePatchRowState) -> String {
        let version = HerdrMousePatchVersion.supported
        switch state {
        case .supportedByHerdr:
            return "On. This herdr passes clicks and scrolling through to panes on its own."
        case .installed(let backupPath):
            return "On. flock installed a build of herdr \(version) that passes clicks and scrolling through "
                + "to your panes. Your original herdr is saved at \(displayPath(backupPath))."
        case .patchable:
            return "Off. herdr \(version) doesn't pass clicks and scrolling through to panes. flock can "
                + "install a build of the same version that does, and keep your original to restore later."
        case .artifactUnavailable:
            return "Not available. This build of flock doesn't include mouse support for herdr \(version)."
        case .notWritable(let installPath):
            return "Off. flock can't write to \(displayPath(installPath)) from this account, so it leaves herdr alone."
        case .unsupportedVersion:
            return "Not available. Mouse support is built for herdr \(version) only, and this herdr is a "
                + "different version."
        }
    }

    public static func actionTitle(for state: HerdrMousePatchRowState) -> String? {
        switch state {
        case .patchable: return "Install"
        case .installed: return "Restore Original"
        case .supportedByHerdr, .artifactUnavailable, .notWritable, .unsupportedVersion: return nil
        }
    }

    /// The single confirmation install always asks, naming the exact path
    /// being replaced. Never remembered as a preference: this is built to be
    /// shown every time, not gated behind a "don't ask again" flag.
    public struct Confirmation: Equatable, Sendable {
        public let title: String
        public let message: String
        public let confirmButtonTitle: String
    }

    public static func installConfirmation(installPath: String) -> Confirmation {
        Confirmation(
            title: "Install mouse support?",
            message: "flock will replace \(displayPath(installPath)) with a build of herdr "
                + "\(HerdrMousePatchVersion.supported) that passes clicks and scrolling through to panes. Your "
                + "original is saved beside it and can be restored here.",
            confirmButtonTitle: "Install"
        )
    }

    public static func revertConfirmation(installPath: String) -> Confirmation {
        Confirmation(
            title: "Restore the original herdr?",
            message: "flock will put back the herdr it saved at "
                + "\(displayPath(HerdrMousePatchInstaller.backupPath(for: installPath))), then delete the saved "
                + "copy once the restore checks out.",
            confirmButtonTitle: "Restore"
        )
    }
}
