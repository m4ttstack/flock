import FlockCore
import SwiftUI

/// One pane opened from Overview, live, under a header that leads back to
/// Overview and on to the next card. The pane is the main window's own canvas in solo
/// mode, so typing, the rt modal and the chat popover work as they do there.
struct FocusedPaneView: View {
    let theme: Theme
    let viewModel: SessionViewModel
    let pane: PaneID

    @Environment(DragCoordinator.self) private var drag
    @Environment(AllWorkspacesModeStore.self) private var mode
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
                .overlay { RtModalView(theme: theme, viewModel: viewModel, solo: pane) }
        }
        // The pane's own modal goes with it: left open, it would pop up over
        // the main window the next time that mounts its own.
        .onChange(of: pane, initial: true) { previous, _ in
            if previous != pane { viewModel.closeRtModal(over: previous) }
            viewModel.paneShownInOverview = pane
        }
        .onDisappear {
            viewModel.closeRtModal(over: pane)
            if viewModel.paneShownInOverview == pane { viewModel.paneShownInOverview = nil }
        }
    }

    private var layout: LayoutSnapshot? {
        viewModel.model?.panes[pane].flatMap { viewModel.model?.layouts[$0.tabID] }
    }

    private var navigator: JumpNavigator {
        JumpNavigator(viewModel: viewModel, drag: drag, mode: mode)
    }

    private func header(now: Date) -> some View {
        let shown = MissionBoard.card(pane, viewModel: viewModel, board: boardNames, herdProgress: herdProgress)
        return HStack(spacing: G.headerSpacing) {
            backButton
            separator
            if let shown { place(shown.card, sections: shown.sections, now: now) }
            Spacer(minLength: 0)
            nextChip(now: now)
        }
        .lineLimit(1)
        .padding(.horizontal, G.headerHorizontalPadding)
        .frame(height: G.headerHeight)
        .background(WindowDragExclusion())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("flock.focused.header")
    }

    private var chipShape: AnyShape { AnyShape(RoundedRectangle(cornerRadius: M.backCornerRadius)) }

    private var backButton: some View {
        GridControlButton(theme: theme, shape: chipShape, restFill: theme.tabRest, restForeground: theme.textStrong) {
            navigator.backToOverview()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left").font(.system(size: 9, weight: .semibold))
                Text("Overview").font(ChromeType.focusedBack)
                keyHint(.backToOverview)
            }
            .padding(.horizontal, M.backHorizontalPadding)
            .frame(height: M.backHeight)
        }
        .overlay(chipShape.stroke(theme.rule, lineWidth: ChromeMetrics.ruleWidth).allowsHitTesting(false))
        .pointerStyle(.link)
        .accessibilityIdentifier("flock.focused.back")
    }

    /// The card the Open Next Card key opens: the oldest other than this
    /// pane's, which is the one the jump key opens here too.
    @ViewBuilder
    private func nextChip(now: Date) -> some View {
        let next = viewModel.attentionToasts.oldest(excluding: pane)
            .flatMap { MissionBoard.card($0.paneID, viewModel: viewModel, board: boardNames, herdProgress: herdProgress) }
        if let next {
            let waiting = viewModel.attentionToasts.count(excluding: pane)
            GridControlButton(theme: theme, shape: chipShape, restFill: theme.tabRest, restForeground: theme.textStrong) {
                navigator.openNext()
            } label: {
                nextLabel(next.card, sections: next.sections, more: waiting - 1, now: now)
            }
            .overlay(chipShape.stroke(theme.rule, lineWidth: ChromeMetrics.ruleWidth).allowsHitTesting(false))
            .pointerStyle(.link)
            // Hugs its label; the title's cap is what keeps a long tab short.
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityIdentifier("flock.focused.next")
        } else {
            Text("Queue clear")
                .font(ChromeType.focusedNextPlace)
                .foregroundStyle(theme.textLabel)
                .padding(.horizontal, M.nextHorizontalPadding)
                .frame(height: M.backHeight)
                .overlay(chipShape.stroke(theme.rule, lineWidth: ChromeMetrics.ruleWidth))
                .fixedSize()
                .accessibilityIdentifier("flock.focused.queueClear")
        }
    }

    private func nextLabel(_ card: MissionCard, sections: RailSections, more: Int, now: Date) -> some View {
        let color = MissionBoard.identityColor(card.workspaceID, sections: sections, identity: identity, theme: theme)
        return HStack(spacing: M.nextSpacing) {
            Text("NEXT")
                .font(ChromeType.focusedNextLabel)
                .tracking(ChromeType.focusedNextLabelTracking)
                .foregroundStyle(theme.textLabel)
            StatusDot(status: card.status, theme: theme, size: M.cardDot)
            Text(card.workspaceName)
                .font(ChromeType.focusedNextPlace)
                .foregroundStyle(theme.identityInk(color))
                .fixedSize()
            Text(card.title)
                .font(ChromeType.focusedNextPlace)
                .foregroundStyle(theme.textStrong)
                .truncationMode(.tail)
                .frame(maxWidth: M.nextMaxTitleWidth, alignment: .leading)
            Text(card.stateText(at: now))
                .font(ChromeType.missionCardMono)
                .foregroundStyle(theme.agentStatusMarkColor(card.status))
                .fixedSize()
            if more > 0 {
                Text("+\(more)")
                    .font(ChromeType.missionCardMono)
                    .foregroundStyle(theme.textLabel)
                    .fixedSize()
            }
            Rectangle()
                .fill(theme.rule)
                .frame(width: ChromeMetrics.ruleWidth, height: G.headerSeparatorHeight)
            keyHint(.openNextCard)
        }
        .padding(.horizontal, M.nextHorizontalPadding)
        .frame(height: M.backHeight)
    }

    private func keyHint(_ command: ViewCommand) -> some View {
        Text(ShortcutLabel.text(key: command.key, modifiers: command.modifiers))
            .font(ChromeType.focusedKey)
            .foregroundStyle(theme.textLabel)
            .fixedSize()
    }

    private var separator: some View {
        Rectangle()
            .fill(theme.rule)
            .frame(width: ChromeMetrics.ruleWidth, height: G.headerSeparatorHeight)
    }

    private func place(_ card: MissionCard, sections: RailSections, now: Date) -> some View {
        let color = MissionBoard.identityColor(card.workspaceID, sections: sections, identity: identity, theme: theme)
        return HStack(spacing: G.headerSpacing) {
            IdentitySquare(theme: theme, identity: color, size: G.focusedIdentitySize, cornerRadius: G.focusedIdentityCornerRadius)
            HStack(spacing: 5) {
                Text(card.workspaceName).foregroundStyle(theme.identityInk(color))
                Text("›").foregroundStyle(theme.textLabel)
                Text(card.title).foregroundStyle(theme.textStrong)
                if let detail = card.detail {
                    Text(detail).foregroundStyle(theme.textDim)
                }
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
