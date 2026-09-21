import Foundation

/// The row's text, one state at a time. Never says "upgrade herdr" or
/// implies the maintainers endorsed this: it states plainly that flock
/// replaces the binary with a build of the same version, keeps a backup, and
/// that it can be undone.
public enum HerdrMousePatchCopy {
    public static let heading = "herdr"

    public static func body(for state: HerdrMousePatchRowState) -> String {
        switch state {
        case .supportedByHerdr:
            return "This herdr already reports mouse events over its CLI. There is nothing to do."
        case .installed(let backupPath):
            return "flock replaced this herdr binary with a build of herdr \(HerdrMousePatchVersion.supported) "
                + "carrying an extra CLI verb for mouse events. The original is kept at \(backupPath)."
        case .patchable(let installPath):
            return "This is herdr \(HerdrMousePatchVersion.supported). flock can replace \(installPath) with a "
                + "build of the same version that also reports mouse events, keep the original as a backup "
                + "beside it, and undo this later."
        case .artifactUnavailable:
            return "flock does not carry a prebuilt patch for herdr \(HerdrMousePatchVersion.supported) in this build."
        case .notWritable(let installPath):
            return "\(installPath) is not writable by this account, so flock will not modify it."
        case .unsupportedVersion:
            return "This herdr is not version \(HerdrMousePatchVersion.supported), the only version this "
                + "build's patch covers."
        }
    }

    public static func actionTitle(for state: HerdrMousePatchRowState) -> String? {
        switch state {
        case .patchable: return "Install"
        case .installed: return "Revert"
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
            title: "Replace \(installPath)?",
            message: "flock will replace \(installPath) with a build of herdr \(HerdrMousePatchVersion.supported) "
                + "that also reports mouse events. The current binary is kept beside it as a backup, and this "
                + "can be undone from the same row.",
            confirmButtonTitle: "Install"
        )
    }

    public static func revertConfirmation(installPath: String) -> Confirmation {
        Confirmation(
            title: "Revert \(installPath)?",
            message: "flock will restore the backup it kept when it patched \(installPath), and remove the "
                + "backup once the restore is verified.",
            confirmButtonTitle: "Revert"
        )
    }
}
