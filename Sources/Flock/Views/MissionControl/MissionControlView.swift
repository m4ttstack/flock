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
    /// One space for every lane, so a card whose lane changes is the same
    /// view moving rather than one fading out and another in.
    @Namespace private var laneSpace

    private typealias M = ChromeMetrics.MissionControl

    var body: some View {
        // The schedule only re-runs the body; the time itself is the view
        // model's clock, so ages and timelines agree with the history.
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            let now = viewModel.currentTime
            if let (board, sections) = makeBoard(now: now) {
                lanes(board, sections: sections, now: now)
                    .onAppear { resolveSelection(in: board) }
                    .onChange(of: board.columns) { resolveSelection(in: board) }
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
        .onAppear { isFocused = true }
    }

    /// The one place the board is built, for drawing and for the keys alike.
    private func makeBoard(now: Date) -> (MissionBoard, RailSections)? {
        MissionBoard.make(viewModel: viewModel, board: boardNames, herdProgress: herdProgress, cutoff: cutoff, now: now)
    }

    private func resolveSelection(in board: MissionBoard) {
        let resolved = MissionSelection.resolve(mode.missionSelection, in: board.columns)
        if resolved != mode.missionSelection { mode.missionSelection = resolved }
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
        // Every lane's ground in one layer behind all lanes' cards: drawn per
        // lane, a later lane's ground would cover a card crossing leftwards.
        .background {
            HStack(spacing: M.laneGap) {
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: M.laneCornerRadius).fill(theme.pane)
                }
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
                // Clipped top and bottom only: a card moving to another lane
                // is drawn by the lane it lands in, and has to stay visible
                // as it crosses from its old lane.
                .scrollClipDisabled()
                .mask { Rectangle().padding(.horizontal, -M.crossLaneReach) }
                .onAppear { if let selected = mode.missionSelection { reader.scrollTo(selected) } }
                .onChange(of: mode.missionSelection) { _, selected in
                    if let selected { withAnimation { reader.scrollTo(selected) } }
                }
            }
            footer().padding(.horizontal, M.selectionInset)
        }
        .padding(M.lanePadding - M.selectionInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
        .matchedGeometryEffect(id: card.paneID, in: laneSpace)
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
        MissionBoard.identityColor(workspace, sections: sections, identity: identity, theme: theme)
    }

    private func move(_ direction: MissionSelection.Direction) -> KeyPress.Result {
        guard let (board, _) = makeBoard(now: viewModel.currentTime) else { return .ignored }
        let current = MissionSelection.resolve(mode.missionSelection, in: board.columns)
        guard current != nil else { return .ignored }
        // A selection that had gone stale lands on the first card rather than
        // moving away from it.
        mode.missionSelection = current == mode.missionSelection
            ? MissionSelection.move(current, direction, in: board.columns)
            : current
        return .handled
    }

    /// Opens the selected card only while it is drawn; a stale selection is
    /// replaced by the first card, which Return then opens.
    private func activateSelection() -> KeyPress.Result {
        guard let (board, _) = makeBoard(now: viewModel.currentTime),
              let pane = MissionSelection.resolve(mode.missionSelection, in: board.columns)
        else { return .ignored }
        guard pane == mode.missionSelection else {
            mode.missionSelection = pane
            return .handled
        }
        open(pane)
        return .handled
    }

    private func open(_ pane: PaneID) {
        mode.missionSelection = pane
        JumpNavigator(viewModel: viewModel, drag: drag, mode: mode).open(pane: pane)
    }
}

extension MissionBoard {
    /// The board as the app's stores hold it, for every view that reads lanes
    /// or dormancy, so mission control and Arrange agree on both.
    @MainActor
    static func make(
        viewModel: SessionViewModel, board: BoardStore, herdProgress: HerdProgressStore,
        cutoff: DormantCutoffStore, now: Date
    ) -> (MissionBoard, RailSections)? {
        guard let model = viewModel.model else { return nil }
        let sections = RailSections(model: model, board: board, herdProgress: herdProgress)
        let missionBoard = MissionBoard(
            model: model, sections: sections, toasts: viewModel.attentionToasts,
            history: viewModel.statusHistory, cutoff: cutoff.active.seconds, now: now
        )
        return (missionBoard, sections)
    }

    /// The identity colour a mission card or an Arrange island wears; nil for
    /// a herd, which has no identity of its own.
    @MainActor
    static func identityColor(
        _ workspace: WorkspaceID, sections: RailSections, identity: WorkspaceIdentityStore, theme: Theme
    ) -> Color? {
        guard let key = WorkspaceIdentityStore.key(for: workspace, sections: sections),
              let index = identity.index(for: key)
        else { return nil }
        let colors = IdentityPalette.colors(for: theme.palette)
        return colors.indices.contains(index) ? Color(colors[index]) : nil
    }
}

extension RailSections {
    /// The rail's sections as the app's stores hold them, for every view that
    /// orders or keys workspaces the way the rail does.
    @MainActor
    init(model: SessionModel, board: BoardStore, herdProgress: HerdProgressStore) {
        self.init(model: model, board: board.names, herdProgress: herdProgress.progress)
    }
}
