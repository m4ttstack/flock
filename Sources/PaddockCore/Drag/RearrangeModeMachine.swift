import Foundation

/// Whether rearrange mode is active, decided PURELY from the two live
/// triggers (a held Control key, the View-menu sticky toggle) and whether a
/// rearrange drag is currently in flight -- no `NSEvent`, view, or
/// `DragController` inside this type, so the whole truth table is testable
/// with plain events.
///
/// `dragInProgress` overrides both triggers while `true`: a drag begun under
/// a held Control must not end the moment Control is released, so releasing
/// Control mid-drag stays active until `.dragEnded` arrives, at which point
/// `active` is recomputed from whatever Control/toggle state holds then.
public struct RearrangeModeMachine: Equatable, Sendable {
    public enum Event: Equatable, Sendable {
        case controlDown
        case controlUp
        case toggleOn
        case toggleOff
        case dragBegan
        case dragEnded
    }

    public private(set) var active = false
    /// The sticky (View-menu) half of the state, exposed separately from
    /// `active` so a caller can tell whether the CURRENT active state (if
    /// any) is soley the momentary Control hold or the sticky toggle -- the
    /// View-menu checkmark reflects only this, never a held Control.
    public private(set) var isToggled = false

    private var controlHeld = false
    private var dragInProgress = false

    public init() {}

    public mutating func handle(_ event: Event) {
        switch event {
        case .controlDown: controlHeld = true
        case .controlUp: controlHeld = false
        case .toggleOn: isToggled = true
        case .toggleOff: isToggled = false
        case .dragBegan: dragInProgress = true
        case .dragEnded: dragInProgress = false
        }
        active = dragInProgress ? true : (controlHeld || isToggled)
    }
}
