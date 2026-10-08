import Foundation

/// Tells a herdr focus move made from outside flock (rt's focus pane, a
/// notification click) from one flock made itself. The outside ones happen
/// while flock is in the background and are followed by flock being raised,
/// so a move between leaving the front and coming back counts. herdr's event
/// can trail the raise, so a move inside `grace` after coming back counts
/// too, unless it lands on `ownTarget`: the pane Overview is showing, whose
/// own focus a click on the way in can send.
public struct ExternalFocusWatch: Equatable, Sendable {
    public static let grace: TimeInterval = 1

    private var away = false
    private var focusWhenLeft: PaneID?
    private var graceEnds: Date?
    private var focusWhenReturned: PaneID?

    public init() {}

    public mutating func left(focus: PaneID?) {
        away = true
        focusWhenLeft = focus
        graceEnds = nil
    }

    /// Whether herdr's focus moved while flock was away.
    public mutating func returned(focus: PaneID?, at now: Date) -> Bool {
        guard away else { return false }
        away = false
        if focus != focusWhenLeft {
            graceEnds = nil
            return true
        }
        graceEnds = now.addingTimeInterval(Self.grace)
        focusWhenReturned = focus
        return false
    }

    /// Whether a model update just brought the outside move in late.
    public mutating func observed(focus: PaneID?, ownTarget: PaneID?, at now: Date) -> Bool {
        guard !away, let ends = graceEnds else { return false }
        guard now <= ends else {
            graceEnds = nil
            return false
        }
        guard focus != focusWhenReturned else { return false }
        graceEnds = nil
        return focus != nil && focus != ownTarget
    }
}
