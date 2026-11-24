import Foundation

/// Whether flock has anything to show at all: every pane is a herdr bridge,
/// so a machine without the binary can drive none of them. Decided from
/// whatever resolved the binary's path, never from a bridge or socket
/// failing later.
///
/// `installOnScreen`: the missing screen began an install that still runs, or
/// that ended in an error not yet read. herdr is on disk before that install
/// is over, so the screen outlasts it being found.
public enum HerdrAvailability {
    public static func shouldShowMissingScreen(herdrBinaryFound: Bool, installOnScreen: Bool) -> Bool {
        !herdrBinaryFound || installOnScreen
    }
}
