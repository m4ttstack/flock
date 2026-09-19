import Foundation

/// The pure decisions behind chat degrading gracefully: what "available"
/// means, what gates a verb, and what disables Open Viewer alone. Absence is
/// decided from what is installed, never from a call's outcome, so nothing
/// here ever inspects an error.
public enum ChatDegradation {
    /// herdr-chat shells out to rt for every verb it runs, so rt missing
    /// collapses to the exact same absence as the plugin binary itself being
    /// missing -- never a call failure for a caller to catch.
    public static func isAvailable(chatBinaryFound: Bool, rtBinaryFound: Bool) -> Bool {
        chatBinaryFound && rtBinaryFound
    }

    /// The one gate every verb passes through before anything is spawned,
    /// pulled out so `ChatStore` and a test of this rule can never disagree.
    public static func shouldRunVerb(isAvailable: Bool) -> Bool { isAvailable }

    /// Open Viewer alone depends on deck (`open-viewer` is deck-sourced), so
    /// its absence disables that one row rather than the whole feature.
    public static func viewerDisabledReason(deckBinaryFound: Bool) -> String? {
        deckBinaryFound ? nil : "Open viewer needs deck, which isn't installed"
    }
}
