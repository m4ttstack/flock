import SwiftUI

/// The View menu's two arrange items, declared together because they are one
/// gesture at two scopes: the plain key arranges the panes of one workspace,
/// the shifted form arranges across all of them. They share a key for that
/// reason, and a change to one is a change to both.
///
/// Command is the one modifier a pane's program never receives, which is what
/// makes a Command key equivalent free to claim at all.
///
/// Not D: ghostty's own macOS defaults bind Cmd+D and Cmd+Shift+D to
/// `new_split`, and flock runs beside a real ghostty on the same machine.
struct ArrangeShortcut: Equatable, Sendable {
    let key: Character
    let modifiers: EventModifiers

    var shortcut: KeyboardShortcut { KeyboardShortcut(KeyEquivalent(key), modifiers: modifiers) }

    static let rearrangeMode = ArrangeShortcut(key: "r", modifiers: .command)
    static let allWorkspaces = ArrangeShortcut(key: "r", modifiers: [.command, .shift])
}
