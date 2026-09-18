import CoreGraphics
import Foundation

/// Where flock's window belongs when it opens again: the frame the last one
/// was written down at, answered against the screens attached now.
///
/// A frame saved against a display that has since been unplugged describes
/// somewhere no pointer can reach, so a saved frame is honoured only while
/// some attached screen still overlaps it, and that screen then constrains
/// it: never larger than the screen, never above the menu bar or hanging off
/// the bottom, and never so far sideways that nothing is left to grab the
/// window back by.
public enum MainWindowFrame {
    /// A rename here orphans every frame already written to disk.
    public static let defaultsKey = "flock.mainWindowFrame"

    /// How much of the window has to stay on its screen for the pointer to be
    /// able to drag it back. A window narrower than this keeps all of itself.
    public static let grabbableWidth: CGFloat = 96

    public static func encoded(_ frame: CGRect) -> String { NSStringFromRect(frame) }

    /// `nil` when there is nothing to honour: nothing saved, something saved
    /// that does not read back as a frame with area, or a frame no attached
    /// screen overlaps.
    public static func restored(from saved: String?, visibleScreenFrames: [CGRect]) -> CGRect? {
        guard let saved else { return nil }
        let frame = NSRectFromString(saved)
        // The stored size, not `width`/`height`: those standardize, so a
        // negative size reads back positive and every edge with it.
        guard frame.size.width > 0, frame.size.height > 0 else { return nil }
        guard let screen = screen(under: frame, among: visibleScreenFrames) else { return nil }
        return constrained(frame, to: screen)
    }

    /// The display a straddling window belongs to is the one it covers most
    /// of, so the answer does not depend on the order the screens arrive in.
    private static func screen(under frame: CGRect, among screens: [CGRect]) -> CGRect? {
        var best: (screen: CGRect, area: CGFloat)?
        for screen in screens {
            let overlap = frame.intersection(screen)
            guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { continue }
            let area = overlap.width * overlap.height
            guard area > (best?.area ?? 0) else { continue }
            best = (screen, area)
        }
        return best?.screen
    }

    /// Vertically the window is put wholly on the screen, which is where
    /// AppKit would have kept it anyway; horizontally it keeps whatever
    /// overhang it was left with, down to the slice the pointer needs.
    static func constrained(_ frame: CGRect, to screen: CGRect) -> CGRect {
        var result = frame
        result.size.width = min(result.width, screen.width)
        result.size.height = min(result.height, screen.height)
        result.origin.y = min(max(result.minY, screen.minY), screen.maxY - result.height)
        let grabbable = min(grabbableWidth, result.width)
        result.origin.x = min(result.minX, screen.maxX - grabbable)
        result.origin.x = max(result.minX, screen.minX - (result.width - grabbable))
        return result
    }
}
