import Foundation

/// Whether rearrange mode is active, decided PURELY from the sticky toggle --
/// the View menu's Rearrange Mode item and its key equivalent are one switch,
/// not two routes -- plus whether a rearrange drag is currently in flight. No
/// `NSEvent`, view, or `DragController` inside this type, so the whole truth
/// table is testable with plain events.
///
/// `dragInProgress` overrides the toggle while `true`: a drag begun in the
/// mode must not end the moment the mode is turned off underneath it, so
/// `active` is recomputed from the toggle only once `.dragEnded` arrives. Esc
/// while a drag is in flight is deliberately NOT this type's concern --
/// cancelling the drag itself is `DragController`'s job, reached through the
/// same `.dragEnded` seam once it settles -- so `.escPressed` is a no-op here
/// whenever `dragInProgress` is true, which is what makes "Esc during a drag
/// takes two presses to leave the mode" fall out for free: the first press
/// only ends the drag, and only a second, drag-free Esc reaches the exit
/// branch below.
public struct RearrangeModeMachine {
    public enum Event: Equatable, Sendable {
        case toggleOn
        case toggleOff
        case dragBegan
        case dragEnded
        case escPressed
    }

    public private(set) var active = false
    /// What the View-menu checkmark reflects. Identical to `active` except
    /// during a drag that outlives the toggle being turned off.
    public private(set) var isToggled = false

    private var dragInProgress = false

    public init() {}

    /// Handles an Esc and answers whether this layer spent it. Only the press
    /// that actually leaves the mode is spent; every other Esc has somewhere
    /// else to be, and the last stop is the program in the focused pane, where
    /// a stray Esc interrupts whatever is running.
    public mutating func handleEscape() -> Bool {
        let wasActive = active
        handle(.escPressed)
        return wasActive && !active
    }

    public mutating func handle(_ event: Event) {
        switch event {
        case .toggleOn:
            isToggled = true
        case .toggleOff:
            isToggled = false
        case .dragBegan:
            dragInProgress = true
        case .dragEnded:
            dragInProgress = false
        case .escPressed:
            if !dragInProgress { isToggled = false }
        }
        active = dragInProgress || isToggled
    }
}
