import FlockCore
import SwiftUI

/// One pane opened from Overview, live, under a header whose only control
/// leads back to Overview. The pane is the main window's own canvas in solo
/// mode, so typing, the rt modal and the chat popover work as they do there.
struct FocusedPaneView: View {
    let theme: Theme
    let viewModel: SessionViewModel
    let pane: PaneID

    @Environment(DragCoordinator.self) private var drag
    @Environment(AllWorkspacesModeStore.self) private var mode
    @Environment(DormantCutoffStore.self) private var cutoff
    @Environment(WorkspaceIdentityStore.self) private var identity
    @Environment(BoardStore.self) private var boardNames
    @Environment(HerdProgressStore.self) private var herdProgress

    private typealias G = ChromeMetrics.Grid
    private typealias M = ChromeMetrics.MissionControl

    var body: some View {
        VStack(spacing: 0) {
            // The schedule only re-runs the header; ages read the view
            // model's clock, as Overview's do.
            TimelineView(.periodic(from: .now, by: 60)) { _ in header(now: viewModel.currentTime) }
            Rectangle()
                .fill(theme.rule)
                .frame(height: ChromeMetrics.ruleWidth)
            PaneCanvas(theme: theme, viewModel: viewModel, layout: layout, solo: pane)
                .overlay { RtModalView(theme: theme, viewModel: viewModel) }
        }
        .onChange(of: pane, initial: true) { previous, _ in
            if previous != pane { closeRtModal() }
            viewModel.paneShownInOverview = pane
        }
        .onDisappear {
            if viewModel.paneShownInOverview == pane { viewModel.paneShownInOverview = nil }
            closeRtModal()
        }
    }

    /// A modal left open here would otherwise pop up over the main window
    /// the next time it mounts its own.
    private func closeRtModal() {
        guard viewModel.rt.modal != nil else { return }
        Task { await viewModel.rt.closeModal(focusingLinked: false) }
    }

    private var layout: LayoutSnapshot? {
        viewModel.model?.panes[pane].flatMap { viewModel.model?.layouts[$0.tabID] }
    }

    private var navigator: JumpNavigator {
        JumpNavigator(viewModel: viewModel, drag: drag, mode: mode)
    }

    private func header(now: Date) -> some View {
        let board = MissionBoard.make(viewModel: viewModel, board: boardNames, herdProgress: herdProgress, cutoff: cutoff, now: now)
        let card = board?.0.card(pane)
        let others = viewModel.attentionToasts.toasts.filter { $0.paneID != pane }.count
        return HStack(spacing: G.headerSpacing) {
            backButton
            separator
            if let board, let card { place(card, sections: board.1, now: now) }
            Spacer(minLength: 0)
            if others > 0 {
                HStack(spacing: 6) {
                    StatusDot(status: .blocked, theme: theme, size: M.cardDot)
                    Text("\(others) more need\(others == 1 ? "s" : "") you")
                        .font(ChromeType.gridCount)
                        .foregroundStyle(theme.textDim)
                }
                separator
            }
            Text("⌘J next · ⇧⌘J overview")
                .font(ChromeType.gridHint)
                .foregroundStyle(theme.textLabel)
        }
        .lineLimit(1)
        .padding(.horizontal, G.headerHorizontalPadding)
        .frame(height: G.headerHeight)
        .background(WindowDragExclusion())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("flock.focused.header")
    }

    private var backButton: some View {
        let shape = AnyShape(RoundedRectangle(cornerRadius: M.toggleCornerRadius))
        return GridControlButton(theme: theme, shape: shape, restFill: theme.tabRest, restForeground: theme.textStrong) {
            navigator.back()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left").font(.system(size: 9, weight: .semibold))
                Text("Overview").font(ChromeType.modeToggle(selected: true))
            }
            .padding(.horizontal, M.toggleSegmentPadding)
            .frame(height: M.toggleHeight)
        }
        .overlay(shape.stroke(theme.rule, lineWidth: ChromeMetrics.ruleWidth).allowsHitTesting(false))
        .pointerStyle(.link)
        .accessibilityIdentifier("flock.focused.back")
    }

    private var separator: some View {
        Rectangle()
            .fill(theme.rule)
            .frame(width: ChromeMetrics.ruleWidth, height: G.headerSeparatorHeight)
    }

    private func place(_ card: MissionCard, sections: RailSections, now: Date) -> some View {
        let color = MissionBoard.identityColor(card.workspaceID, sections: sections, identity: identity, theme: theme)
        return HStack(spacing: G.headerSpacing) {
            RoundedRectangle(cornerRadius: G.focusedIdentityCornerRadius)
                .fill(color ?? theme.textLabel)
                .frame(width: G.focusedIdentitySize, height: G.focusedIdentitySize)
            HStack(spacing: 5) {
                Text(card.workspaceName).foregroundStyle(color ?? theme.textLabel)
                Text("›").foregroundStyle(theme.textLabel)
                Text(card.tabTitle).foregroundStyle(theme.textStrong)
            }
            .font(ChromeType.focusedPlace)
            .truncationMode(.middle)
            HStack(spacing: 6) {
                StatusDot(status: card.status, theme: theme, size: M.cardDot)
                Text(card.stateText(at: now))
                    .font(ChromeType.missionCardMono)
                    .foregroundStyle(theme.agentStatusMarkColor(card.status))
            }
            .padding(.leading, 4)
            .fixedSize()
        }
    }
}
