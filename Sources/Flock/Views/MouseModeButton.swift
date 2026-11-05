import FlockCore
import SwiftUI

/// A pane's right-click mode, shown while its program has the mouse: the left
/// clicker is filled at the default, right-clicks opening flock's menu, and
/// empty when they go to the program. A click flips the mode.
struct MouseModeButton: View {
    let theme: Theme
    let paneID: PaneID
    let mode: RightClickMode
    let onToggle: (() -> Void)?

    private typealias M = ChromeMetrics.PaneBar

    var body: some View {
        Button {
            onToggle?()
        } label: {
            MouseGlyph(isFilled: mode == .menu)
                .frame(width: M.glyphSize, height: M.glyphSize)
        }
        .buttonStyle(PaneBarKeyStyle(style: LauncherStripStyle(theme: theme)))
        .disabled(onToggle == nil)
        .delayedTip(tip, shortcut: "⌥⌘M")
        .accessibilityLabel("Right-clicks")
        .accessibilityValue(mode == .menu ? "flock's menu" : "the program")
        .accessibilityIdentifier("flock.pane.mouseBadge.\(paneID.rawValue)")
    }

    private var tip: String {
        mode == .menu ? "Right-clicks open flock's menu" : "Right-clicks go to the program"
    }
}

/// Takes the button's foreground, so it brightens with the key.
struct MouseGlyph: View {
    let isFilled: Bool

    private typealias M = ChromeMetrics.PaneBar

    var body: some View {
        ZStack {
            if isFilled { PaneMouseClicker().fill(.foreground) }
            PaneMouseOutline(hasDivider: !isFilled)
                .stroke(style: StrokeStyle(lineWidth: M.glyphStroke, lineCap: .round, lineJoin: .round))
        }
    }
}
