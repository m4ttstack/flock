import AppKit
import FlockCore
import SwiftUI

extension Theme {
    /// The ground of an Arrange island and of an Overview group: one faint
    /// neutral for every workspace, since hue is how status is told.
    var workspaceWash: Color {
        textLabel.opacity(ChromeMetrics.Grid.islandTint)
    }
}

/// The rail's menu for a workspace, on a view outside the rail: its own rows
/// from `WorkspaceMenuModel`, with Change Symbol... after Rename when the
/// workspace's mark is a symbol. A workspace the rail gives no menu (Board's,
/// a herd's) gets none here.
private struct WorkspaceMenu: ViewModifier {
    let viewModel: SessionViewModel
    let workspace: WorkspaceID
    let key: String?
    let changeSymbol: (() -> Void)?

    @ViewBuilder
    func body(content: Content) -> some View {
        if WorkspaceIdentityStore.isRailRow(key: key) {
            content.contextMenu {
                if let model = viewModel.model {
                    let pin = viewModel.pins.pin(linkedTo: workspace)
                    ForEach(WorkspaceMenuModel.entries(for: workspace, model: model, isPinned: pin != nil), id: \.accessibilityIdentifier) { entry in
                        Button(entry.label) {
                            if entry.action == .changeFolder, let pin {
                                if let folder = FolderPanel.choose(current: pin.folder, message: "Where \"\(pin.name)\" opens") {
                                    viewModel.setPinFolder(pin.id, to: folder)
                                }
                            } else {
                                Task { await entry.action.perform(workspaceID: workspace, on: viewModel) }
                            }
                        }
                        .accessibilityIdentifier(entry.accessibilityIdentifier)
                        if entry.action == .rename, let changeSymbol {
                            Button("Change Symbol\u{2026}", action: changeSymbol)
                                .accessibilityIdentifier("flock.identity.symbol.menu")
                        }
                    }
                }
            }
        } else {
            content
        }
    }
}

extension View {
    func workspaceMenu(
        viewModel: SessionViewModel, workspace: WorkspaceID, key: String?, changeSymbol: (() -> Void)?
    ) -> some View {
        modifier(WorkspaceMenu(viewModel: viewModel, workspace: workspace, key: key, changeSymbol: changeSymbol))
    }
}

private struct EmptyPinMenu: ViewModifier {
    let viewModel: SessionViewModel
    let pin: PinnedWorkspace
    let beginRename: () -> Void
    let changeSymbol: () -> Void

    func body(content: Content) -> some View {
        content.contextMenu {
            ForEach(EmptyPinMenuModel.entries(), id: \.accessibilityIdentifier) { entry in
                Button(entry.label) {
                    switch entry.action {
                    case .rename: beginRename()
                    case .changeFolder:
                        if let folder = FolderPanel.choose(current: pin.folder, message: "Where \"\(pin.name)\" opens") {
                            viewModel.setPinFolder(pin.id, to: folder)
                        }
                    case .remove: viewModel.removePin(pin.id)
                    }
                }
                .accessibilityIdentifier(entry.accessibilityIdentifier)
                if entry.action == .rename {
                    Button("Change Symbol\u{2026}", action: changeSymbol)
                        .accessibilityIdentifier("flock.identity.symbol.menu")
                }
            }
        }
    }
}

extension View {
    func emptyPinMenu(
        viewModel: SessionViewModel, pin: PinnedWorkspace, beginRename: @escaping () -> Void, changeSymbol: @escaping () -> Void
    ) -> some View {
        modifier(EmptyPinMenu(viewModel: viewModel, pin: pin, beginRename: beginRename, changeSymbol: changeSymbol))
    }
}

/// What marks a workspace beside its name outside the rail, matching how the
/// rail marks its sections: the board app's logo for board's workspaces, the
/// ram for a herd, otherwise the workspace's symbol. `key` is its
/// `WorkspaceIdentityStore` key, which already says which it is.
///
/// Given `picking`, a mark that draws a symbol is a button that opens the
/// symbol picker anchored to itself. The logo and the ram have nothing to
/// pick, so they stay plain.
struct WorkspaceMark: View {
    let theme: Theme
    let key: String?
    let size: CGFloat
    var picking: Binding<Bool>?
    var forced: ControlInteraction?

    @Environment(BoardStore.self) private var board
    @Environment(WorkspaceIdentityStore.self) private var identityStore

    static func drawsSymbol(key: String?, logo: NSImage?, in store: WorkspaceIdentityStore) -> Bool {
        guard let key, !(key == WorkspaceIdentityStore.boardKey && logo != nil) else { return false }
        return store.symbol(for: key) != nil
    }

    var body: some View {
        if let picking, Self.drawsSymbol(key: key, logo: board.logo, in: identityStore) {
            let padding = ChromeMetrics.MarkButton.padding
            GridControlButton(
                theme: theme, shape: AnyShape(RoundedRectangle(cornerRadius: ChromeMetrics.MarkButton.cornerRadius)),
                restForeground: theme.textStrong, forced: forced, action: { picking.wrappedValue = true }
            ) {
                mark.padding(padding)
            }
            .padding(-padding)
            .pointerStyle(.link)
            .help("Change symbol")
            .workspaceSymbolPopover(theme: theme, key: key, isPresented: picking)
            .accessibilityLabel("Change symbol")
            .accessibilityIdentifier("flock.identity.symbol.button")
        } else {
            mark
        }
    }

    @ViewBuilder
    private var mark: some View {
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
