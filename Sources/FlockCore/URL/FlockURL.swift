import Foundation

/// The only way into flock from outside the app.
///
/// Every value here arrives from a process flock does not control, so parsing
/// refuses anything it does not recognise outright rather than reading past
/// it. The shape leaves room for more verbs; the rule that they stay
/// non-destructive is in this feature's spec, not enforceable here.
public enum FlockURL {
    /// The prod bundle's scheme.
    public static let scheme = "flock"
    /// The dev bundle's. Two installed copies would otherwise register the
    /// same scheme, and macOS picks ONE handler for a scheme with no
    /// guarantee it is the copy that is running.
    public static let devScheme = "flock-dev"

    public enum Request: Equatable, Sendable {
        case focusPane(PaneID)
    }

    public static func parse(_ url: URL) -> Request? {
        guard let scheme = url.scheme?.lowercased(), scheme == Self.scheme || scheme == devScheme else {
            return nil
        }
        // `URLComponents` rather than `url.query`: it is what decodes the
        // percent-encoding a colon in a pane id needs.
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        guard components.host?.lowercased() == "focus" else { return nil }
        guard
            let pane = components.queryItems?.first(where: { $0.name == "pane" })?.value,
            !pane.isEmpty
        else { return nil }
        return .focusPane(PaneID(rawValue: pane))
    }
}
