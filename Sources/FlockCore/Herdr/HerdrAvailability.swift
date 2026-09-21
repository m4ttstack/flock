import Foundation

/// Whether flock has anything to show at all: every pane is a herdr bridge,
/// so a machine without the binary can drive none of them. Decided from
/// whatever resolved the binary's path, never from a bridge or socket
/// failing later.
public enum HerdrAvailability {
    public static func shouldShowMissingScreen(herdrBinaryFound: Bool) -> Bool {
        !herdrBinaryFound
    }
}
