import Foundation

/// Whether to put the patch banner in front of someone who has not asked for
/// it, given what detection found and what they have already said.
///
/// Only `.patchable` is ever offered. The other five states have nothing to
/// act on: already installed, herdr reports mouse events itself, the wrong
/// version, a location flock will not write to, or no artifact in this
/// build. Offering in any of those would be an interruption with no button
/// behind it.
///
/// A dismissal is remembered against the herdr version it was given for, not
/// forever. Someone who says no to patching the herdr they have now has said
/// nothing about the herdr they install next month, and that upgrade is
/// exactly when the offer becomes worth making again.
///
/// This gates the OFFER and nothing else. The install confirmation is a
/// separate thing and is shown every single time, including from this
/// banner: `HerdrMousePatchCopy.Confirmation` is explicit that it is never
/// remembered as a preference, and the banner must not become the loophole
/// that makes it one.
public enum HerdrMousePatchOffer {
    public static func shouldOffer(
        state: HerdrMousePatchRowState?,
        dismissedForVersion: String?,
        currentVersion: String = HerdrMousePatchVersion.supported
    ) -> Bool {
        guard case .patchable = state else { return false }
        return dismissedForVersion != currentVersion
    }

    public static let bannerHeadline = "This herdr cannot report mouse events"
    public static let bannerDetail =
        "flock can replace it with a build of the same version that does, keeping the original beside it."
    public static let bannerActionTitle = "Install"
    public static let bannerDismissTitle = "Not now"
}
