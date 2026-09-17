import AppKit
import SwiftUI

/// Hands the window's keyboard to the text field this is placed behind, by
/// asking AppKit outright.
///
/// SwiftUI's own `@FocusState` request is made once, as the editor appears,
/// and it is DROPPED when an AppKit view holds first responder at that
/// moment, which is exactly the case an inline rename opens in: the focused
/// pane's terminal is holding it. The flag stays true afterwards, so nothing
/// re-asks, and the editor sits on screen with no keyboard at all. Measured,
/// in a live window: the first keystroke after opening a tab's editor reached
/// the pane's shell, and every one after it reached nothing.
///
/// So the claim is made here instead, and made the way AppKit answers
/// unconditionally. It is idempotent -- it checks who holds first responder
/// before asking, and asks again on every pass it is given -- because the
/// moment a claim can succeed is not the moment the editor appears.
struct FirstResponderClaim: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ClaimHostView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ClaimHostView)?.claim()
    }

    /// Invisible and untouchable: it exists to reach the window and the field
    /// beside it, never to draw or to take a click of its own.
    final class ClaimHostView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            claim()
            // SwiftUI inserts the views of one pass in an order this cannot
            // depend on, so the field may not be in the hierarchy yet when
            // this fires. One turn later it is.
            DispatchQueue.main.async { [weak self] in self?.claim() }
        }

        /// Makes the editor's field the window's first responder and selects
        /// what it holds, so the next keystroke replaces the old name rather
        /// than appending to it. Does nothing at all once the field already
        /// has it, so the repeat calls this deliberately makes are free.
        ///
        /// Both resting shapes count as held: AppKit answers a text field's
        /// own claim with its field editor, and a window can also name the
        /// field itself, so a guard that knew only the first would re-claim
        /// (and re-select) over a caret the user had already moved.
        func claim() {
            guard let window, let field = Self.field(near: self) else { return }
            guard window.firstResponder !== field, window.firstResponder !== field.currentEditor() else { return }
            guard window.makeFirstResponder(field) else { return }
            field.currentEditor()?.selectAll(nil)
        }

        /// The text field this claim belongs to: the one in the container it
        /// was placed in, searched outward until a level holds one. A
        /// background's view is a sibling of what it backs, so the first level
        /// almost always answers; the walk outward is what keeps this from
        /// depending on that.
        ///
        /// A level holding MORE than one field is refused rather than guessed
        /// at. paddock draws at most one editor at a time and has no other
        /// text field anywhere, so two would mean the structure this reads is
        /// not the structure it was written for, and claiming the wrong one
        /// would put the user's keystrokes somewhere else entirely -- the
        /// exact failure this whole claim exists to end.
        private static func field(near view: NSView) -> NSTextField? {
            var level = view.superview
            while let current = level {
                let found = fields(in: current)
                if found.count > 1 {
                    assertionFailure("a rename editor's container holds \(found.count) text fields; refusing to guess")
                    return nil
                }
                if let only = found.first { return only }
                level = current.superview
            }
            return nil
        }

        private static func fields(in view: NSView) -> [NSTextField] {
            view.subviews.flatMap { subview -> [NSTextField] in
                if let field = subview as? NSTextField { return [field] }
                return fields(in: subview)
            }
        }
    }
}
