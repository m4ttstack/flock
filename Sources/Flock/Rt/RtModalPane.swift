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
        // The schedule only wakes the view at the ceiling, the one input that
        // changes with time alone; everything else it reads is observed.
        return TimelineView(.explicit(ceilingDates)) { _ in
            let covered = coversPane(at: Date())
            ZStack(alignment: .topLeading) {
                theme.terminalGround
                if let surface {
                    GhosttyPaneTerminalView(
                        surface: surface, grid: grid, theme: theme, isFocused: isFocused,
                        fontSizePoints: fontSizePoints, optionAsAlt: optionAsAltStore.active,
                        rearrangeActive: false, paneDragInProgress: false, isPristineLauncherPane: false,
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
        }
        .task(id: paneID) { surface = await viewModel.attachPane(paneID) }
        .onDisappear { Task { await viewModel.detachPane(paneID) } }
    }

    private var ceilingDates: [Date] {
        guard let startedAt = command?.startedAt else { return [] }
        return [startedAt.addingTimeInterval(RtModalLoaderPolicy.ceiling)]
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
