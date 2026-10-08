import Foundation

/// Tells a herdr focus move made from outside flock (rt's focus pane, a
/// notification click) from one flock made itself. The outside ones happen
/// while flock is in the background and are followed by flock being raised,
/// so a move between leaving the front and coming back counts. herdr's event
/// can trail the raise, so a move inside `grace` after coming back counts
/// too. A move onto `ownTarget`, the pane Overview is showing, never counts:
/// Overview's own queued focus can land on either side of the raise. A nil
/// focus is a model not yet known, never a move.
public struct ExternalFocusWatch: Equatable, Sendable {
    public static let grace: TimeInterval = 1

    private var away = false
    private var focusWhenLeft: PaneID?
    private var graceEnds: Date?

    public init() {}

    public mutating func left(focus: PaneID?) {
        away = true
        focusWhenLeft = focus
        graceEnds = nil
    }

    /// Whether herdr's focus moved while flock was away.
    public mutating func returned(focus: PaneID?, ownTarget: PaneID?, at now: Date) -> Bool {
        guard away else { return false }
        away = false
        if isMove(to: focus, ownTarget: ownTarget) {
            graceEnds = nil
            return true
        }
        graceEnds = now.addingTimeInterval(Self.grace)
        return false
    }

    /// Whether a model update just brought the outside move in late.
    public mutating func observed(focus: PaneID?, ownTarget: PaneID?, at now: Date) -> Bool {
        guard !away, let ends = graceEnds else { return false }
        guard now <= ends else {
            graceEnds = nil
            return false
        }
        guard isMove(to: focus, ownTarget: ownTarget) else { return false }
        graceEnds = nil
        return true
    }

    private func isMove(to focus: PaneID?, ownTarget: PaneID?) -> Bool {
        guard let focus, let focusWhenLeft else { return false }
        return focus != focusWhenLeft && focus != ownTarget
    }
}
