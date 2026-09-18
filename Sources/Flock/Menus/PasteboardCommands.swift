import AppKit
import SwiftUI

/// The standard editing items, and the only reason Cmd+V ever reaches a pane
/// as a paste at all: with no pasteboard group in this app's menu bar the key
/// equivalent belongs to nobody, so AppKit hands the event to the focused
/// pane's `keyDown` and it leaves as a bare Cmd+V keystroke.
///
/// Every item dispatches to the RESPONDER CHAIN (`NSApp.sendAction` with a nil
/// target), never to the focused pane directly. The chain is what already
/// tells a pane from an open rename field: while an editor is up its field
/// editor holds first responder (the pane's surface stands down for exactly
/// this -- see `TerminalFocusClaim`), so the field editor takes the paste and
/// the terminal underneath never sees it. With nothing on the chain claiming
/// an action `sendAction` returns false and the keystroke does nothing, which
/// is the point: it no longer arrives in a terminal as a raw Cmd+V.
///
/// Four items, not five: ghostty binds Cmd+Shift+V to `paste_from_selection`
/// on macOS, and flock has no selection clipboard to paste from -- it declares
/// `supports_selection_clipboard: false` and its read-clipboard callback
/// refuses `GHOSTTY_CLIPBOARD_SELECTION` -- so that item would be a shortcut
/// that silently does nothing.
struct PasteboardCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .pasteboard) {
            // Cut has no terminal meaning and the pane's surface implements
            // none. It is here for the rename editor, which is a real text
            // field and does.
            item("Cut", #selector(NSText.cut(_:)), "x", "flock.edit.cut")
            item("Copy", #selector(NSText.copy(_:)), "c", "flock.edit.copy")
            item("Paste", #selector(NSText.paste(_:)), "v", "flock.edit.paste")
            Divider()
            item("Select All", #selector(NSText.selectAll(_:)), "a", "flock.edit.selectAll")
        }
    }

    private func item(
        _ title: String, _ action: Selector, _ key: KeyEquivalent, _ accessibilityIdentifier: String
    ) -> some View {
        Button(title) { _ = NSApp.sendAction(action, to: nil, from: nil) }
            .keyboardShortcut(key, modifiers: .command)
            .accessibilityIdentifier(accessibilityIdentifier)
    }
}
