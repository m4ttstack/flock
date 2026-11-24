import Foundation

/// Whether to put the install banner in front of someone who has not asked
/// for it. Only `.stock` and `.outdated` have a button behind them.
///
/// A dismissal is remembered against the newest build offered, so the next
/// published build makes the offer again. It gates the offer only: the
/// install confirmation is shown every time.
public enum HerdrBuildOffer {
    public static func shouldOffer(state: HerdrBuildState?, dismissedFor: String?) -> Bool {
        guard let state, let token = dismissalToken(for: state) else { return false }
        return dismissedFor != token
    }

    public static func dismissalToken(for state: HerdrBuildState) -> String? {
        switch state {
        case .stock(_, _, let newest), .outdated(_, _, let newest): newest
        case .missing, .current, .notWritable, .checking, .listUnavailable: nil
        }
    }

    public static func hasAction(for state: HerdrBuildState?) -> Bool {
        state.flatMap(dismissalToken(for:)) != nil
    }

    public static func bannerHeadline(for state: HerdrBuildState?) -> String {
        switch state {
        case .outdated(_, _, let newest): "herdr \(newest) is available"
        default: "This herdr isn't the mattstack build"
        }
    }

    public static func bannerDetail(for state: HerdrBuildState?) -> String {
        if case .outdated = state { return "flock can update it without closing your panes." }
        return "flock can install it so clicks, scrolling and themes reach your panes."
    }

    public static func bannerActionTitle(for state: HerdrBuildState?) -> String {
        if case .outdated = state { return "Update" }
        return "Install"
    }

    public static let bannerDismissTitle = "Not now"
}
