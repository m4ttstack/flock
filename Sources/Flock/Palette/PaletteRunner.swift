import FlockCore
import SwiftUI

extension PaletteContext {
    /// This moment, read the way each command's own menu item or button reads it.
    @MainActor
    static func current(viewModel: SessionViewModel, chatStore: ChatStore, rtInstalled: Bool) -> PaletteContext {
        let focused = viewModel.resolvedFocusedPaneID
        let record = focused.flatMap { viewModel.model?.panes[$0] }
        let terminal = record?.terminalID
        return PaletteContext(
            canvasPane: viewModel.canvasFocusedPaneID,
            neighbors: Set(PaneDirection.allCases.filter { viewModel.focusedPaneHasNeighbor(toward: $0) }),
            rtModalUp: viewModel.rt.modal != nil,
            rtInstalled: rtInstalled && terminal != nil,
            rtCommands: terminal.map { viewModel.rt.commandRows(linkedTo: $0) } ?? [],
            chatRows: ChatMenuModel.rows(
                isAvailable: chatStore.isAvailable, hasFocusedPane: focused != nil,
                isSignedIn: focused.flatMap { chatStore.status(for: $0) }?.signedIn ?? false,
                viewerDisabledReason: chatStore.viewerDisabledReason
            ),
            focusedAgent: record?.agent,
            rightClickMode: viewModel.focusedPaneRightClickMode,
            programHasMouse: focused.flatMap { viewModel.ghosttySurface(for: $0) }?.programHasMouse ?? false,
            hasSelectedWorkspace: viewModel.selectedWorkspaceID != nil,
            hasNotifications: !viewModel.attentionToasts.isEmpty
        )
    }
}

/// Runs a palette row the way its menu item or button does.
@MainActor
struct PaletteRunner {
    let viewModel: SessionViewModel
    let chatStore: ChatStore
    let rearrangeMode: RearrangeMode
    let dragCoordinator: DragCoordinator

    func run(_ action: PaletteAction) {
        switch action {
        case .paneMenu(let paneAction):
            guard let pane = viewModel.canvasFocusedPaneID else { return }
            Task { await paneAction.perform(paneID: pane, on: viewModel) }
        case .direction(let command):
            Task {
                switch command.kind {
                case .focus: await viewModel.focusNeighbor(toward: command.direction)
                case .move: await viewModel.moveFocusedPane(toward: command.direction)
                case .swap: await viewModel.swapFocusedPane(toward: command.direction)
                }
            }
        case .chat(let item):
            item.perform(chatStore: chatStore, viewModel: viewModel)
        case .rt(let kind):
            guard let pane = viewModel.resolvedFocusedPaneID, let record = viewModel.fullModel?.panes[pane] else { return }
            Task { await viewModel.rt.open(kind, from: record) }
        case .toggleRightClicks:
            viewModel.toggleFocusedPaneRightClicks()
        case .view(let command):
            switch command {
            case .newTab:
                guard let workspace = viewModel.selectedWorkspaceID else { return }
                Task { await viewModel.createTab(in: workspace) }
            case .newWorkspace: Task { await viewModel.createWorkspace() }
            case .rearrangeMode: rearrangeMode.toggle()
            case .allWorkspaces: dragCoordinator.toggleGrid()
            case .openOldestNotification: Task { await viewModel.jumpToOldestDisplayedAttentionToast() }
            case .clearNotifications: viewModel.clearAttentionToasts()
            case .commandPalette: break
            }
        }
    }
}
