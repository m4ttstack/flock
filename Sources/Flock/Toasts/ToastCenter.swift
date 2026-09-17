import Foundation
import Observation
import FlockCore

/// The in-window toast slot: one toast at a time, the newest replacing the
/// last, auto-dismissed after `dismissAfter`. Deliberately single-slot with
/// no persistence or click behavior; the attention-toast stack extends it.
@MainActor
@Observable
final class ToastCenter {
    enum Kind: String {
        case copied
        /// Undo/redo journal notices (stale entry dropped, partial undo,
        /// plan/herdr failure) -- always window-scope (`paneID == nil`),
        /// rendered by `ToastHost` in the window's top-right corner, with
        /// the undo-arrow glyph.
        case notice
        /// A command-surface outcome that is NOT about undo/redo (an
        /// invalid move, a plan/herdr failure from `perform`/`closePane`)
        /// -- also window-scope, but with a neutral info glyph rather than
        /// the undo arrow, since nothing here is undoing anything.
        case info
    }

    struct Toast: Identifiable, Equatable {
        let id: UUID
        let kind: Kind
        let message: String
        /// The pane this toast anchors to, drawn by that pane's own cell;
        /// `nil` is a window-scope toast, drawn by `ToastHost` instead --
        /// every `.notice` toast is window-scope, `.copied` is pane-scope.
        let paneID: PaneID?

        var accessibilityIdentifier: String { "flock.toast.\(kind.rawValue)" }
    }

    private(set) var current: Toast?
    @ObservationIgnored private var dismissTask: Task<Void, Never>?

    init() {}

    /// A journal notice reads as a sentence, not a one-glance confirmation
    /// like the copied whisper -- it stays up long enough to actually read.
    private static func dismissAfter(for kind: Kind) -> Duration {
        switch kind {
        case .copied: return .milliseconds(1200)
        case .notice, .info: return .milliseconds(2500)
        }
    }

    /// Window-scope notice (the undo journal's own sink): always `paneID:
    /// nil`, so `ToastHost` -- never a pane cell -- renders it.
    func show(_ message: String) {
        show(message, kind: .notice, in: nil)
    }

    func show(_ message: String, kind: Kind, in paneID: PaneID? = nil) {
        let toast = Toast(id: UUID(), kind: kind, message: message, paneID: paneID)
        current = toast
        dismissTask?.cancel()
        let dismissAfter = Self.dismissAfter(for: kind)
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: dismissAfter)
            guard !Task.isCancelled else { return }
            self?.dismiss(toast.id)
        }
    }

    /// Clears `current` only if it is still the toast that asked; a newer
    /// toast's own timer owns its dismissal.
    func dismiss(_ id: Toast.ID) {
        guard current?.id == id else { return }
        current = nil
    }
}
