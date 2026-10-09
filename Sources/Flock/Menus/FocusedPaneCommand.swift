import FlockCore
import SwiftUI

/// One menu-bar command aimed at the focused pane. Carries a `PaneMenuAction`
/// rather than a verb of its own, so the key and the pane's own right-click
/// row can never come to run different things.
///
/// Command is the one modifier a pane's program never receives, which is what
/// makes a Command key equivalent free to claim at all.
struct FocusedPaneCommand: Equatable, Sendable {
    let title: String
    let key: Character
    let modifiers: EventModifiers
    let action: PaneMenuAction
    let accessibilityIdentifier: String
    /// Overview's pane is drawn alone, so a split or zoom there would change
    /// a layout no one can see.
    let paletteSurfaces: Set<PaletteSurface>

    var shortcut: KeyboardShortcut { KeyboardShortcut(KeyEquivalent(key), modifiers: modifiers) }

    /// D, and Shift for the downward one, are ghostty's own macOS defaults for
    /// `new_split`, so the keys that split a real ghostty split a flock pane.
    /// `ArrangeShortcut` left them free for this.
    static let splitRight = FocusedPaneCommand(
        title: "Split Right", key: "d", modifiers: .command,
        action: .splitRight, accessibilityIdentifier: "flock.pane.splitRight",
        paletteSurfaces: [.workspaces]
    )
    static let splitDown = FocusedPaneCommand(
        title: "Split Down", key: "d", modifiers: [.command, .shift],
        action: .splitDown, accessibilityIdentifier: "flock.pane.splitDown",
        paletteSurfaces: [.workspaces]
    )
    /// Shift-Command-Return is ghostty's macOS default for
    /// `toggle_split_zoom`, on the same reasoning as the split keys.
    static let zoom = FocusedPaneCommand(
        title: "Zoom Pane", key: "\r", modifiers: [.command, .shift],
        action: .zoom, accessibilityIdentifier: "flock.pane.zoomPane",
        paletteSurfaces: [.workspaces]
    )
    /// Command-W is ghostty's `close_surface`; the File menu's Close Tab and
    /// Close Workspace are its Shift and Option+Shift steps outward.
    static let closePane = FocusedPaneCommand(
        title: "Close Pane", key: "w", modifiers: .command,
        action: .closePane, accessibilityIdentifier: "flock.file.closePane",
        paletteSurfaces: [.workspaces, .overviewPane]
    )

    static let all: [FocusedPaneCommand] = [splitRight, splitDown, zoom, closePane]
    /// The Pane menu's rows; Close Pane lives in File beside the other closes.
    static let paneMenu: [FocusedPaneCommand] = [splitRight, splitDown, zoom]

    /// `title` stays the command's identity; this is what the row reads.
    func title(zoomed: Bool) -> String {
        action == .zoom && zoomed ? "Unzoom Pane" : title
    }
}
