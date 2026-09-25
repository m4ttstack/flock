import AppKit
import FlockCore
import SwiftUI

/// The Chat menu's seven rows, in the order and with the shortcuts
/// `measurements.md`'s own "Menu bar" section gives. A real `Commands` menu
/// is drawn by AppKit and cannot be inspected from a test, so this is the
/// one place that order lives: `ChatCommands.body` builds its real menu by
/// walking exactly this list, and a test asserts the list itself.
enum ChatMenuItem: String, CaseIterable, Equatable {
    case chatPanel, broadcast, peek, quickSend, openViewer, signIn, signOut

    var title: String {
        switch self {
        case .chatPanel: "Chat Panel"
        case .broadcast: "Broadcast to Panes…"
        case .peek: "Chat Peek"
        case .quickSend: "Quick Send…"
        case .openViewer: "Open Viewer"
        case .signIn: "Sign In This Pane"
        case .signOut: "Sign Out This Pane"
        }
    }

    var key: Character {
        switch self {
        case .chatPanel: "c"
        case .broadcast: "b"
        case .peek: "p"
        case .quickSend: "s"
        case .openViewer: "v"
        case .signIn: "i"
        case .signOut: "o"
        }
    }

    /// Drawn immediately before this item: after Chat Panel and after Open
    /// Viewer, per `measurements.md`.
    var hasSeparatorBefore: Bool {
        self == .broadcast || self == .signIn
    }
}

/// What the Chat menu draws for one moment of flock: nil when chat itself
/// is unavailable, which is the whole point -- no button, no menu, no
/// dialogue, never a list of disabled rows standing in for one.
enum ChatMenuModel {
    struct Row: Equatable {
        let item: ChatMenuItem
        let isEnabled: Bool
    }

    static func rows(
        isAvailable: Bool, hasFocusedPane: Bool, isSignedIn: Bool, viewerDisabledReason: String?
    ) -> [Row]? {
        guard isAvailable else { return nil }
        return ChatMenuItem.allCases.map { item in
            Row(
                item: item,
                isEnabled: isEnabled(
                    item, hasFocusedPane: hasFocusedPane, isSignedIn: isSignedIn,
                    viewerDisabledReason: viewerDisabledReason
                )
            )
        }
    }

    /// Every row needs a focused pane to act on; Open Viewer additionally
    /// needs deck, and the two sign rows are each other's mirror image.
    private static func isEnabled(
        _ item: ChatMenuItem, hasFocusedPane: Bool, isSignedIn: Bool, viewerDisabledReason: String?
    ) -> Bool {
        guard hasFocusedPane else { return false }
        switch item {
        case .openViewer: return viewerDisabledReason == nil
        case .signIn: return !isSignedIn
        case .signOut: return isSignedIn
        case .chatPanel, .broadcast, .peek, .quickSend: return true
        }
    }
}

/// The real menu bar wiring: `FlockApp` constructs this and drops it into
/// its `.commands` block, keeping the menu's own logic out of a file
/// `FlockChromeRender` cannot compile (`ChatMenuModel` above is what a test
/// reaches instead).
///
/// `rows` arrives already computed, read from `FlockApp.body`'s own
/// `.commands` closure rather than from `chatStore`/`viewModel` in here: that
/// closure is the one place in this app SwiftUI is proven to re-evaluate on
/// an `@Observable` change (`FlockApp.swift`'s `.disabled(viewModel
/// .selectedWorkspaceID == nil)`), and a `Commands` conformer holding only
/// plain `let`s has no such guarantee for its own `body`.
struct ChatCommands: Commands {
    let chatStore: ChatStore
    let viewModel: SessionViewModel
    let rows: [ChatMenuModel.Row]?

    var body: some Commands {
        if let rows {
            CommandMenu("Chat") {
                ForEach(rows, id: \.item) { row in
                    if row.item.hasSeparatorBefore { Divider() }
                    Button(row.item.title) { row.item.perform(chatStore: chatStore, viewModel: viewModel) }
                        .keyboardShortcut(KeyEquivalent(row.item.key), modifiers: [.command, .shift])
                        .disabled(!row.isEnabled)
                        .accessibilityIdentifier("flock.chat.menu.\(row.item.rawValue)")
                }
            }
        }
    }
}

extension ChatMenuItem {
    /// Chat Panel opens the popover's status root, since that IS the panel;
    /// Broadcast, Peek and Quick Send each land directly on their own
    /// sub-view -- a shortcut names an action, so it must deliver that
    /// action, not a launcher the user still has to navigate.
    @MainActor
    func perform(chatStore: ChatStore, viewModel: SessionViewModel) {
        guard let pane = viewModel.resolvedFocusedPaneID else { return }
        switch self {
        case .chatPanel:
            chatStore.requestPopover(for: pane)
        case .broadcast:
            chatStore.requestPopover(for: pane, feature: .broadcast)
        case .peek:
            chatStore.requestPopover(for: pane, feature: .peek)
        case .quickSend:
            chatStore.requestPopover(for: pane, feature: .quickSend)
        case .openViewer:
            Task {
                guard let url = await chatStore.viewerURL(room: nil) else { return }
                NSWorkspace.shared.open(url)
            }
        case .signIn:
            Task { await chatStore.signIn(pane) }
        case .signOut:
            Task { await chatStore.signOut(pane) }
        }
    }
}
