import Foundation

/// Whether rearrange mode is active, decided PURELY from three live triggers
/// -- a held modifier key, a double-tap of that same key, and the View-menu
/// sticky toggle -- plus whether a rearrange drag is currently in flight and
/// an injected clock for the tap timing, so the whole truth table (including
/// the timing rules) is testable with plain events and no real waiting. No
/// `NSEvent`, view, or `DragController` inside this type. Which physical key
/// the held/tapped trigger is bound to is a policy decision made above this
/// type (currently `RearrangeMode`, Option); the machine only knows "the
/// held modifier is down or up," never a key name, so a future rebinding
/// never has to touch this file.
///
/// `dragInProgress` overrides every trigger while `true`: a drag begun under
/// the held modifier must not end the moment it is released, so releasing it
/// mid-drag stays active until `.dragEnded` arrives, at which point `active`
/// is recomputed from whatever modifier/toggle state holds then. Esc while a
/// drag is in flight is deliberately NOT this type's concern -- cancelling
/// the drag itself is `DragController`'s job, reached through the same
/// `.dragEnded` seam once it settles -- so `.escPressed` is a no-op here
/// whenever `dragInProgress` is true, which is what makes "Esc during a
/// sticky-mode drag takes two presses to leave the mode" fall out for free:
/// the first press only ends the drag (via the drag layer), and only a
/// second, drag-free Esc reaches the exit-sticky branch below.
public struct RearrangeModeMachine {
    public enum Event: Equatable, Sendable {
        case modifierDown
        case modifierUp
        /// The modifier is being treated as released because the window/app
        /// lost the ability to observe it (resign-key, resign-active), not
        /// because a real key-up arrived. Unlike `.modifierUp` this never
        /// registers or completes a tap -- an interrupted hold forced off
        /// this way must not be misread as a suspiciously short, clean tap
        /// -- and it discards any in-progress press and pending tap outright,
        /// since nothing about their timing can be trusted once observation
        /// resumes.
        case modifierForcedUp
        case toggleOn
        case toggleOff
        case dragBegan
        case dragEnded
        /// Esc is itself a key event, so like `.otherInputOccurred` it
        /// disqualifies whatever press is currently in progress from ever
        /// counting as a tap and cancels a pending first-tap wait, in
        /// addition to its own precedence effect on drag/sticky state below.
        case escPressed
        /// Any key or mouse event that is not the modifier itself and not
        /// Esc. Feeding this disqualifies whatever press is currently in
        /// progress from ever counting as a tap, and cancels a pending
        /// first-tap wait -- this is the rule that keeps Option-modified
        /// typing (Option held, then a letter key, in a terminal) from ever
        /// being read as a tap.
        case otherInputOccurred
    }

    /// A press of `tapCeiling` OR LESS is a tap candidate (inclusive: a
    /// press of exactly 300ms still qualifies); anything longer is a hold,
    /// never a tap. Decided at the moment its `.modifierUp` arrives (there
    /// is no mid-press timer; the machine only ever sees discrete down/up
    /// events, so "longer than the ceiling" is necessarily evaluated in
    /// arrears -- nothing observable depends on catching it earlier, since a
    /// hold already activates the mode immediately on `.modifierDown`, same
    /// as it always did).
    public static let tapCeiling: Duration = .milliseconds(300)
    /// The longest silence between one qualifying tap's release and the next
    /// press that can still complete a double-tap, inclusive: a gap of
    /// exactly 400ms still completes it.
    public static let tapGapCeiling: Duration = .milliseconds(400)

    public private(set) var active = false
    /// The sticky half only -- what the View-menu checkmark reflects, and
    /// what a completed double-tap also flips. A held modifier with this
    /// `false` reads `false` here even while `active`.
    public private(set) var isToggled = false

    private var modifierHeld = false
    private var dragInProgress = false
    /// When the modifier currently being held went down, for the tap-length
    /// check at its `.modifierUp`. `nil` whenever the modifier is up.
    private var pressStartedAt: ContinuousClock.Instant?
    /// Cleared to `false` by `.otherInputOccurred` while a press is in
    /// progress, so that press can never complete a tap even if it turns
    /// out to be short.
    private var pressWasClean = true
    /// The timestamp of a qualifying first tap's release, while a second tap
    /// within `tapGapCeiling` could still complete the double-tap. `nil`
    /// when there is no pending tap.
    private var pendingTapAt: ContinuousClock.Instant?

    private let now: () -> ContinuousClock.Instant

    public init(now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.now = now
    }

    public mutating func handle(_ event: Event) {
        switch event {
        case .modifierDown:
            modifierHeld = true
            if let pendingTapAt, now() - pendingTapAt > Self.tapGapCeiling {
                self.pendingTapAt = nil
            }
            pressStartedAt = now()
            pressWasClean = true
        case .modifierUp:
            modifierHeld = false
            handleModifierUp()
        case .modifierForcedUp:
            modifierHeld = false
            pressStartedAt = nil
            pressWasClean = true
            pendingTapAt = nil
        case .toggleOn:
            isToggled = true
        case .toggleOff:
            isToggled = false
        case .dragBegan:
            dragInProgress = true
        case .dragEnded:
            dragInProgress = false
        case .escPressed:
            disqualifyCurrentPress()
            if !dragInProgress, isToggled {
                isToggled = false
                modifierHeld = false
            }
        case .otherInputOccurred:
            disqualifyCurrentPress()
        }
        active = dragInProgress ? true : (modifierHeld || isToggled)
    }

    /// Cancels a pending first-tap wait outright, and marks whatever press
    /// is currently in progress (if any) as no longer eligible to become a
    /// tap once it releases -- shared by `.escPressed` and
    /// `.otherInputOccurred`, the two events that are not the modifier
    /// itself but can still land inside or between taps.
    private mutating func disqualifyCurrentPress() {
        pendingTapAt = nil
        if pressStartedAt != nil {
            pressWasClean = false
        }
    }

    /// A qualifying tap (clean, at or under `tapCeiling`) either completes a
    /// pending first tap -- flipping the sticky toggle, the double-tap route
    /// -- or becomes the new pending first tap itself. A hold, or a press
    /// something else interrupted, is never a tap and clears any pending one
    /// (a hold sandwiched between two clean taps breaks the sequence rather
    /// than being silently skipped).
    private mutating func handleModifierUp() {
        let downAt = pressStartedAt
        let clean = pressWasClean
        pressStartedAt = nil
        pressWasClean = true
        guard let downAt, clean, now() - downAt <= Self.tapCeiling else {
            pendingTapAt = nil
            return
        }
        if pendingTapAt != nil {
            pendingTapAt = nil
            isToggled.toggle()
        } else {
            pendingTapAt = now()
        }
    }
}
