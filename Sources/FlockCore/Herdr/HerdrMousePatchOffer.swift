import Foundation

/// Whether to put the patch banner in front of someone who has not asked for
/// it, given what detection found and what they have already said.
///
/// Only `.patchable` and `.outdated` are ever offered. The other states have
/// nothing to act on: already installed, herdr reports mouse events itself,
/// the wrong version, a location flock will not write to, or no artifact in
/// this build. Offering in any of those would be an interruption with no
/// button behind it.
///
/// A dismissal is remembered against what was offered, not forever: the herdr
/// version for an install, the newer patch's release name for an update.
/// Someone who says no to patching the herdr they have now has said nothing
/// about the herdr they install next month, or about the next revision of the
/// patch, and those are exactly when the offer becomes worth making again.
///
/// This gates the OFFER and nothing else. The install confirmation is a
/// separate thing and is shown every single time, including from this
/// banner: `HerdrMousePatchCopy.Confirmation` is explicit that it is never
/// remembered as a preference, and the banner must not become the loophole
/// that makes it one.
public enum HerdrMousePatchOffer {
    public static func shouldOffer(
        state: HerdrMousePatchRowState?,
        dismissedForVersion: String?
    ) -> Bool {
        guard let state, let token = dismissalToken(for: state) else { return false }
        return dismissedForVersion != token
    }

    /// What a dismissal of the offer for `state` is remembered against, nil
    /// for a state that is never offered.
    public static func dismissalToken(for state: HerdrMousePatchRowState) -> String? {
        switch state {
        case .patchable(_, let version): version
        case .outdated(_, _, let release, _): release
        case .supportedByHerdr, .installed, .notWritable, .unsupportedVersion: nil
        }
    }

    /// Whether the banner's pill has something to do for `state`.
    public static func hasAction(for state: HerdrMousePatchRowState?) -> Bool {
        state.flatMap(dismissalToken(for:)) != nil
    }

    public static func bannerHeadline(for state: HerdrMousePatchRowState?) -> String {
        if case .outdated = state { return "flock has a newer herdr patch" }
        return "This herdr cannot report mouse events"
    }

    public static func bannerDetail(for state: HerdrMousePatchRowState?) -> String {
        if case .outdated = state { return "Panes can follow light or dark themes." }
        return "flock can install a patch to fix this!"
    }

    public static func bannerActionTitle(for state: HerdrMousePatchRowState?) -> String {
        if case .outdated = state { return "Update" }
        return "Install"
    }

    public static let bannerDismissTitle = "Not now"
}
