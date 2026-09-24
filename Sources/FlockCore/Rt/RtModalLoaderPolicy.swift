import Foundation

/// When the rt modal stops covering its pane with the loader: once the
/// program is up, not merely started. herdr calls a pane busy the moment its
/// process starts, well before an rt-ui program has drawn anything, so busy
/// alone uncovers the shell's leftovers mid-transition. Every program the
/// modal runs claims the mouse as it takes the screen, so that claim is the
/// signal; the ceiling covers one that never claims it.
public enum RtModalLoaderPolicy {
    /// Seconds from the start to uncover a program that never claims the
    /// mouse. A backstop, not the signal: rt-ui usually draws well inside it.
    public static let ceiling: TimeInterval = 1.5

    /// `sinceStart` is nil for an item that has not started, and for one
    /// restored from an earlier run, which has been up longer than any ceiling.
    public static func coversPane(started: Bool, ended: Bool, programClaimedMouse: Bool, sinceStart: TimeInterval?) -> Bool {
        if ended || programClaimedMouse { return false }
        guard started else { return true }
        guard let sinceStart else { return false }
        return sinceStart < ceiling
    }
}
