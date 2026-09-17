/// Which of its three lives one drag gesture is in, decided purely from the
/// events a view or an event monitor reports -- no AppKit, no view, no
/// `DragController` inside this type, so the whole truth table is testable
/// with plain events.
///
/// The gate that earns this its own type: a drag STARTS from `.idle` only.
/// One press can reach more than one arming path (a pane body's AppKit
/// handler and a SwiftUI gesture over the same cell both see it while
/// rearranging), and the second arm has to be a no-op rather than a second
/// drag, or the ghost, the grab point and the commit all belong to whichever
/// path happened to run last.
///
/// `cancelledAwaitingRelease` is the other reason: Esc ends a drag while the
/// button is still down, and until it comes up nothing may move and nothing
/// new may start.
public struct DragGestureMachine: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case idle
        case live
        case cancelledAwaitingRelease
    }

    public enum Event: Equatable, Sendable {
        /// A view reports a press that has travelled far enough to be a drag.
        case begin
        /// Esc, with the button still down.
        case cancel
        /// The mouse button came up.
        case release
        /// No release is ever coming to this window (the app resigned active
        /// with the button still down).
        case abandon
    }

    /// What the caller must DO about an event, which is not the same as what
    /// the state did: a duplicate arm moves nothing and must also do nothing.
    public enum Effect: Equatable, Sendable {
        case start
        /// End the drag that was running and commit what it resolved.
        case end
        /// Tear the drag down, committing nothing.
        case cancel
        case none
    }

    public private(set) var state: State = .idle

    /// Whether pointer motion belongs to a live drag. False through the whole
    /// cancelled-awaiting-release stretch, which is what stops the ghost
    /// following the cursor after Esc.
    public var tracksMotion: Bool { state == .live }

    public init() {}

    @discardableResult
    public mutating func handle(_ event: Event) -> Effect {
        switch (state, event) {
        case (.idle, .begin):
            state = .live
            return .start
        case (.live, .cancel):
            state = .cancelledAwaitingRelease
            return .cancel
        case (.live, .release):
            state = .idle
            return .end
        case (.live, .abandon):
            state = .idle
            return .cancel
        case (.cancelledAwaitingRelease, .release), (.cancelledAwaitingRelease, .abandon):
            state = .idle
            return .none
        case (.live, .begin), (.cancelledAwaitingRelease, .begin),
             (.idle, .cancel), (.cancelledAwaitingRelease, .cancel),
             (.idle, .release), (.idle, .abandon):
            return .none
        }
    }
}
