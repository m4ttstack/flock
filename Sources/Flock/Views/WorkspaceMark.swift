import FlockCore
import SwiftUI

extension Theme {
    /// The ground of an Arrange island and of an Overview group: one faint
    /// neutral for every workspace, since hue is how status is told.
    var workspaceWash: Color {
        textLabel.opacity(ChromeMetrics.Grid.islandTint)
    }
}

/// A workspace's right-click "Symbol…" item, which opens its picker popover.
/// Empty for a herd, which has no key and draws the ram.
struct WorkspaceSymbolMenuItem: View {
    let key: String?
    let open: () -> Void

    var body: some View {
        if key != nil {
            Button("Symbol\u{2026}", action: open)
                .accessibilityIdentifier("flock.identity.symbol.menu")
        }
    }
}

/// What marks a workspace beside its name outside the rail, matching how the
/// rail marks its sections: the board app's logo for board's workspaces, the
/// ram for a herd, otherwise the workspace's symbol. `key` is its
/// `WorkspaceIdentityStore` key, which already says which it is.
struct WorkspaceMark: View {
    let theme: Theme
    let key: String?
    let size: CGFloat

    @Environment(BoardStore.self) private var board
    @Environment(WorkspaceIdentityStore.self) private var identityStore

    var body: some View {
        if key == WorkspaceIdentityStore.boardKey, let logo = board.logo {
            Image(nsImage: logo)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else if let key {
            Group {
                if let symbol = identityStore.symbol(for: key) {
                    Image(systemName: symbol)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .foregroundStyle(theme.textStrong)
                } else {
                    Color.clear
                }
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
        } else {
            HerdMark(theme: theme, size: size, isMoving: false)
                .frame(width: size, height: size)
        }
    }
}
