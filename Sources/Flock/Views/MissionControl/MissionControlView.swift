import FlockCore
import SwiftUI

/// The All Workspaces view's mission-control mode. `MissionBoard` decides the
/// lanes; this draws them, refreshes ages once a minute, and moves the
/// keyboard selection.
struct MissionControlView: View {
    let theme: Theme
    let viewModel: SessionViewModel

    @Environment(DragCoordinator.self) private var drag
    @Environment(AllWorkspacesModeStore.self) private var mode
    @Environment(DormantCutoffStore.self) private var cutoff
    @Environment(WorkspaceIdentityStore.self) private var identity
    @Environment(BoardStore.self) private var boardNames
    @Environment(HerdProgressStore.self) private var herdProgress
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isFocused: Bool
    @State private var showsDormant = false

    private typealias M = ChromeMetrics.MissionControl

    var body: some View {
        // The schedule only re-runs the body; the time itself is the view
        // model's clock, so ages and timelines agree with the history.
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            let now = viewModel.currentTime
            if let model = viewModel.model {
                let sections = RailSections(model: model, board: boardNames.names, herdProgress: herdProgress.progress)
                let board = MissionBoard(
                    model: model, sections: sections, toasts: viewModel.attentionToasts,
                    history: viewModel.statusHistory, cutoff: cutoff.active.seconds, now: now
                )
                lanes(board, sections: sections, now: now)
                    .onAppear {
                        if mode.missionSelection == nil {
                            mode.missionSelection = MissionSelection.move(nil, .down, in: board.columns)
                        }
                    }
            }
        }
        .padding(.horizontal, M.canvasPadding)
        .padding(.vertical, M.canvasVerticalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.canvas)
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        // Outside `focusable`: key presses reach the focused view and its
        // ancestors, never a child of it.
        .onKeyPress(.upArrow) { move(.up) }
        .onKeyPress(.downArrow) { move(.down) }
        .onKeyPress(.leftArrow) { move(.left) }
        .onKeyPress(.rightArrow) { move(.right) }
        .onKeyPress(.return) { activateSelection() }
        .onAppear {
            isFocused = true
            viewModel.repoBranches.invalidate()
        }
    }

    private func lanes(_ board: MissionBoard, sections: RailSections, now: Date) -> some View {
        HStack(alignment: .top, spacing: M.laneGap) {
            lane(title: "NEEDS YOU", status: .blocked, count: board.needsYou.count) {
                if board.needsYou.isEmpty {
                    Text("Nothing needs you").font(ChromeType.missionEmpty).foregroundStyle(theme.textLabel)
                }
                ForEach(board.needsYou) { card($0, sections: sections, now: now, showsWorkspace: true, cooling: false) }
            } footer: {
                EmptyView()
            }
            lane(title: "WORKING", status: .working, count: board.working.reduce(0) { $0 + $1.cards.count }) {
                ForEach(board.working) { group in
                    groupLabel(group.name)
                    ForEach(group.cards) { card($0, sections: sections, now: now, showsWorkspace: false, cooling: false) }
                }
            } footer: {
                EmptyView()
            }
            lane(title: "COOLING DOWN", status: .idle, count: board.coolingDown.count) {
                ForEach(board.coolingDown) { card($0, sections: sections, now: now, showsWorkspace: true, cooling: true) }
            } footer: {
                if !board.dormant.isEmpty { dormantFold(board.dormant) }
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: M.laneMoveDuration), value: board)
    }

    private func lane<Content: View, Footer: View>(
        title: String, status: AgentStatus, count: Int,
        @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer
    ) -> some View {
        let cards = content()
        return VStack(alignment: .leading, spacing: M.cardGap - M.selectionInset) {
            HStack(spacing: M.laneHeaderSpacing) {
                StatusDot(status: status, theme: theme, size: M.laneDot)
                Text(title).font(ChromeType.missionLaneTitle).tracking(1.28).foregroundStyle(theme.textLabel)
                Text("\(count)").font(ChromeType.missionLaneCount).foregroundStyle(theme.textLabel)
            }
            .padding(.horizontal, M.selectionInset)
            ScrollViewReader { reader in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: M.cardGap) { cards }
                        .padding(M.selectionInset)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.never)
                .scrollBounceBehavior(.basedOnSize, axes: .vertical)
                .onAppear { if let selected = mode.missionSelection { reader.scrollTo(selected) } }
                .onChange(of: mode.missionSelection) { _, selected in
                    if let selected { withAnimation { reader.scrollTo(selected) } }
                }
            }
            footer().padding(.horizontal, M.selectionInset)
        }
        .padding(M.lanePadding - M.selectionInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.pane, in: RoundedRectangle(cornerRadius: M.laneCornerRadius))
    }

    private func groupLabel(_ name: String) -> some View {
        HStack(spacing: 8) {
            Text(name).font(ChromeType.missionGroupLabel).foregroundStyle(theme.textLabel)
            Rectangle().fill(theme.rule).frame(height: ChromeMetrics.ruleWidth)
        }
        .padding(.top, M.groupLabelTopPadding)
    }

    private func card(_ card: MissionCard, sections: RailSections, now: Date, showsWorkspace: Bool, cooling: Bool) -> some View {
        MissionCardView(
            theme: theme, card: card, showsWorkspace: showsWorkspace,
            identity: identityColor(card.workspaceID, sections: sections),
            repoBranch: viewModel.repoBranches.repoBranch(for: card.folder),
            segments: viewModel.statusHistory.segments(of: card.paneID, at: now), now: now,
            isSelected: mode.missionSelection == card.paneID, isCooling: cooling,
            activate: { open(card.paneID) }
        )
        .id(card.paneID)
    }

    private func dormantFold(_ dormant: [MissionCard]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { showsDormant.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: showsDormant ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                    Text("\(dormant.count) dormant").font(ChromeType.missionGroupLabel)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(theme.textLabel)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("flock.mission.dormant")
            if showsDormant {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(dormant) { card in
                            HStack(spacing: 8) {
                                StatusDot(status: card.status, theme: theme, size: M.cardDot)
                                Text("\(card.workspaceName) › \(card.tabTitle)").foregroundStyle(theme.textLabel)
                                Text(card.title).foregroundStyle(theme.textDim)
                            }
                            .font(ChromeType.missionCardMeta)
                            .lineLimit(1)
                            .contentShape(Rectangle())
                            .onTapGesture { open(card.paneID) }
                        }
                    }
                }
                .scrollIndicators(.never)
                .scrollBounceBehavior(.basedOnSize, axes: .vertical)
                .frame(maxHeight: 220)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: M.cardCornerRadius).strokeBorder(theme.rule, lineWidth: ChromeMetrics.ruleWidth))
    }

    private func identityColor(_ workspace: WorkspaceID, sections: RailSections) -> Color? {
        guard let key = WorkspaceIdentityStore.key(for: workspace, sections: sections),
              let index = identity.index(for: key)
        else { return nil }
        let colors = IdentityPalette.colors(for: theme.palette)
        return colors.indices.contains(index) ? Color(colors[index]) : nil
    }

    private func move(_ direction: MissionSelection.Direction) -> KeyPress.Result {
        guard let model = viewModel.model else { return .ignored }
        let board = MissionBoard(
            model: model, sections: RailSections(model: model, board: boardNames.names, herdProgress: herdProgress.progress),
            toasts: viewModel.attentionToasts, history: viewModel.statusHistory,
            cutoff: cutoff.active.seconds, now: viewModel.currentTime
        )
        mode.missionSelection = MissionSelection.move(mode.missionSelection, direction, in: board.columns)
        return .handled
    }

    private func activateSelection() -> KeyPress.Result {
        guard let pane = mode.missionSelection else { return .ignored }
        open(pane)
        return .handled
    }

    private func open(_ pane: PaneID) {
        mode.missionSelection = pane
        JumpNavigator(viewModel: viewModel, drag: drag, mode: mode).open(pane: pane)
    }
}
