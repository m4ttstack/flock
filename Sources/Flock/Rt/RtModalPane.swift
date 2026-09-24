import FlockCore
import SwiftUI

/// One hidden pane on its ghostty surface. It attaches and parks like a
/// canvas cell, through the view model's per-pane chain.
///
/// While the item's own command is on its way up (`RtModalLoaderPolicy`), the
/// pane loader runs over the pane instead. The surface stays mounted
/// underneath at zero opacity: libghostty needs a real window to render into.
struct RtModalPane: View {
    /// What the item's own command has done so far. A service pane has none:
    /// nothing was typed into it, so nothing ever covers it.
    struct Command: Equatable {
        let started: Bool
        let startedAt: Date?
        let ended: Bool
    }

    let theme: Theme
    let viewModel: SessionViewModel
    let paneID: PaneID
    let grid: PTYSize
    let surfaceSize: CGSize
    let fontSizePoints: Double
    let isFocused: Bool
    let command: Command?
    let onFocus: () -> Void

    @Environment(OptionAsAltStore.self) private var optionAsAltStore
    @State private var surface: (any GhosttyPaneSurface)?
    /// The time the loader rule reads: set when the view appears and again
    /// when the ceiling passes, the one input that changes with time alone.
    @State private var clock = Date()

    init(
        theme: Theme, viewModel: SessionViewModel, paneID: PaneID, grid: PTYSize, surfaceSize: CGSize,
        fontSizePoints: Double, isFocused: Bool, command: Command?, onFocus: @escaping () -> Void
    ) {
        self.theme = theme
        self.viewModel = viewModel
        self.paneID = paneID
        self.grid = grid
        self.surfaceSize = surfaceSize
        self.fontSizePoints = fontSizePoints
        self.isFocused = isFocused
        self.command = command
        self.onFocus = onFocus
        _surface = State(initialValue: viewModel.ghosttySurface(for: paneID))
    }

    var body: some View {
        // Read here, unconditionally, as a canvas cell reads it: the surface
        // re-asserts its claim on the keyboard on every update, so it has to
        // hear an editor open, and a body that skips this read is one that an
        // editor's opening never invalidates.
        let editorIsOpen = viewModel.renameEditorIsOnScreen
        let covered = coversPane(at: clock)
        return ZStack(alignment: .topLeading) {
            theme.terminalGround
            if let surface {
                GhosttyPaneTerminalView(
                    surface: surface, grid: grid, theme: theme, isFocused: isFocused,
                    fontSizePoints: fontSizePoints, optionAsAlt: optionAsAltStore.active,
                    rearrangeActive: false, rightClickMode: .programOnly,
                    paneDragInProgress: false, isPristineLauncherPane: false,
                    editorIsOpen: editorIsOpen, onPrimaryClick: onFocus, menuProvider: { nil }, onBodyDragBegan: { _ in }
                )
                .frame(width: surfaceSize.width, height: surfaceSize.height, alignment: .topLeading)
                .opacity(surface.hasFirstFrame && !covered ? 1 : 0)
            }
        }
        .overlay {
            if covered {
                PaneLoaderView(theme: theme)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: PaneLoaderPolicy.dismissCrossFade), value: covered)
        .task(id: paneID) { surface = await viewModel.attachPane(paneID) }
        // Keyed on the start, which usually lands after the view appeared:
        // the deadline does not exist until then.
        .task(id: command?.startedAt) {
            guard let startedAt = command?.startedAt else { return }
            let wait = startedAt.addingTimeInterval(RtModalLoaderPolicy.ceiling).timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled else { return }
            clock = Date()
        }
        .onDisappear { Task { await viewModel.detachPane(paneID) } }
    }

    private func coversPane(at now: Date) -> Bool {
        guard let command else { return false }
        return RtModalLoaderPolicy.coversPane(
            started: command.started, ended: command.ended,
            programClaimedMouse: surface?.hasClaimedMouse ?? false,
            sinceStart: command.startedAt.map { now.timeIntervalSince($0) }
        )
    }
}
