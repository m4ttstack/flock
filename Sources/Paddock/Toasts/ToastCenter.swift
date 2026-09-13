import Foundation
import Observation
import PaddockCore

/// The in-window toast slot: one toast at a time, the newest replacing the
/// last, auto-dismissed after `dismissAfter`. Deliberately single-slot with
/// no persistence or click behavior; the attention-toast stack extends it.
@MainActor
@Observable
final class ToastCenter {
    enum Kind: String {
        case copied
    }

    struct Toast: Identifiable, Equatable {
        let id: UUID
        let kind: Kind
        let message: String
        /// The pane this toast anchors to, drawn by that pane's own cell;
        /// `nil` is a window-scope toast, drawn by `ToastHost` instead (no
        /// `nil` case exists yet -- reserved for the attention-toast stack).
        let paneID: PaneID?

        var accessibilityIdentifier: String { "paddock.toast.\(kind.rawValue)" }
    }

    private(set) var current: Toast?
    private let dismissAfter: Duration
    @ObservationIgnored private var dismissTask: Task<Void, Never>?

    init(dismissAfter: Duration = .milliseconds(1200)) {
        self.dismissAfter = dismissAfter
    }

    func show(_ message: String, kind: Kind, in paneID: PaneID? = nil) {
        let toast = Toast(id: UUID(), kind: kind, message: message, paneID: paneID)
        current = toast
        dismissTask?.cancel()
        dismissTask = Task { [weak self, dismissAfter] in
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
