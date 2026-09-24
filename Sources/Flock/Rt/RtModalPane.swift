import FlockCore
import SwiftUI

/// One hidden pane on its ghostty surface. It attaches and parks like a
/// canvas cell, through the view model's per-pane chain.
struct RtModalPane: View {
    let theme: Theme
    let viewModel: SessionViewModel
    let paneID: PaneID
    let grid: PTYSize
    let surfaceSize: CGSize
    let fontSizePoints: Double
    let isFocused: Bool
    let onFocus: () -> Void

    @Environment(OptionAsAltStore.self) private var optionAsAltStore
    @State private var surface: (any GhosttyPaneSurface)?

    init(
        theme: Theme, viewModel: SessionViewModel, paneID: PaneID, grid: PTYSize, surfaceSize: CGSize,
        fontSizePoints: Double, isFocused: Bool, onFocus: @escaping () -> Void
    ) {
        self.theme = theme
        self.viewModel = viewModel
        self.paneID = paneID
        self.grid = grid
        self.surfaceSize = surfaceSize
        self.fontSizePoints = fontSizePoints
        self.isFocused = isFocused
        self.onFocus = onFocus
        _surface = State(initialValue: viewModel.ghosttySurface(for: paneID))
    }

    var body: some View {
        // Read here, unconditionally, as a canvas cell reads it: the surface
        // re-asserts its claim on the keyboard on every update, so it has to
        // hear an editor open, and a body that skips this read is one that an
        // editor's opening never invalidates.
        let editorIsOpen = viewModel.renameEditorIsOnScreen
        return ZStack(alignment: .topLeading) {
            theme.terminalGround
            if let surface {
                GhosttyPaneTerminalView(
                    surface: surface, grid: grid, theme: theme, isFocused: isFocused,
                    fontSizePoints: fontSizePoints, optionAsAlt: optionAsAltStore.active,
                    rearrangeActive: false, paneDragInProgress: false, isPristineLauncherPane: false,
                    editorIsOpen: editorIsOpen, onPrimaryClick: onFocus, menuProvider: { nil }, onBodyDragBegan: { _ in }
                )
                .frame(width: surfaceSize.width, height: surfaceSize.height, alignment: .topLeading)
                .opacity(surface.hasFirstFrame ? 1 : 0)
            }
        }
        .task(id: paneID) { surface = await viewModel.attachPane(paneID) }
        .onDisappear { Task { await viewModel.detachPane(paneID) } }
    }
}
