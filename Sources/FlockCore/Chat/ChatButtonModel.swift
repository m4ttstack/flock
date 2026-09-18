import Foundation

/// What a pane's chat button draws: the trigger and the pane's chat state in
/// one control. `unread` is a plain parameter rather than something read off
/// `status`, since the count and the sign-in status arrive from different
/// sources.
public enum ChatButtonModel {
    public enum Appearance: Equatable {
        case absent
        case signedOut
        case signedIn(handle: String, unread: Int)
    }

    /// Chat unavailable on this machine draws no button at all. Available but
    /// with no status yet (the probe has not answered for this pane) reads as
    /// signed out, never as absent -- the two are states a caller must never
    /// collapse into one another.
    public static func appearance(availability: Bool, status: ChatStatus?, unread: Int) -> Appearance {
        guard availability else { return .absent }
        guard let status, status.signedIn, let handle = status.handle else { return .signedOut }
        return .signedIn(handle: displayHandle(handle), unread: unread)
    }

    /// The design's own handle carries no `@`; `ChatStatus.handle` always
    /// does (it is rt's own printed form), so this is the one place that
    /// difference is resolved rather than left for every view to repeat.
    private static func displayHandle(_ handle: String) -> String {
        handle.hasPrefix("@") ? String(handle.dropFirst()) : handle
    }
}
