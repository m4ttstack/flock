import Foundation

/// Attributes a pasteboard change to the pane whose app just took a
/// forwarded left-button release. An app that has claimed the mouse makes
/// its own selection and copies it itself, and its OSC 52 write goes to
/// herdr's TUI client rather than flock's attach, so no surface ever reports
/// the copy: a pasteboard change count moving soon after the release is the
/// only sign flock gets.
public struct PaneAppCopyWatch: Sendable {
    /// Seconds after the release a change still counts as that pane's copy.
    public static let window: TimeInterval = 1.5

    private var armed: (pane: PaneID, baseline: Int, deadline: TimeInterval)?

    public init() {}

    public var isArmed: Bool { armed != nil }

    public mutating func arm(pane: PaneID, changeCount: Int, now: TimeInterval) {
        armed = (pane, changeCount, now + Self.window)
    }

    /// The pane the change belongs to, once; nil while nothing changed or
    /// after the window lapsed, which disarms the watch.
    public mutating func observe(changeCount: Int, now: TimeInterval) -> PaneID? {
        guard let current = armed else { return nil }
        guard now <= current.deadline else {
            armed = nil
            return nil
        }
        guard changeCount != current.baseline else { return nil }
        armed = nil
        return current.pane
    }
}
