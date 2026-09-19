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
struct ChatCommands: Commands {
    let chatStore: ChatStore
    let viewModel: SessionViewModel

    var body: some Commands {
        if let rows = ChatMenuModel.rows(
            isAvailable: chatStore.isAvailable, hasFocusedPane: viewModel.resolvedFocusedPaneID != nil,
            isSignedIn: focusedStatus?.signedIn ?? false, viewerDisabledReason: chatStore.viewerDisabledReason
        ) {
            CommandMenu("Chat") {
                ForEach(rows, id: \.item) { row in
                    if row.item.hasSeparatorBefore { Divider() }
                    Button(row.item.title) { perform(row.item) }
                        .keyboardShortcut(KeyEquivalent(row.item.key), modifiers: [.command, .shift])
                        .disabled(!row.isEnabled)
                        .accessibilityIdentifier("flock.chat.menu.\(row.item.rawValue)")
                }
            }
        }
    }

    private var focusedStatus: ChatStatus? {
        viewModel.resolvedFocusedPaneID.flatMap { chatStore.status(for: $0) }
    }

    /// Chat Panel, Broadcast, Peek and Quick Send all open the focused
    /// pane's popover at its status root -- landing directly on a feature's
    /// own sub-view from a global shortcut is not wired yet, since doing so
    /// needs the popover's route exposed as init state, which no other row
    /// here requires.
    private func perform(_ item: ChatMenuItem) {
        guard let pane = viewModel.resolvedFocusedPaneID else { return }
        switch item {
        case .chatPanel, .broadcast, .peek, .quickSend:
            chatStore.requestPopover(for: pane)
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
