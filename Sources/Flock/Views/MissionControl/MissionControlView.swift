import AppKit
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
    @Environment(MissionBottomLineStore.self) private var bottomLine
    @Environment(BoardStore.self) private var boardNames
    @Environment(WorkspaceIdentityStore.self) private var identityStore
    @Environment(HerdProgressStore.self) private var herdProgress
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// One space for every lane, so a card whose lane changes is the same
    /// view moving rather than one fading out and another in.
    @Namespace private var laneSpace
    /// The group whose symbol picker is open, named by its first card: a
    /// workspace can have a group in every lane, but a pane is in only one.
    @State private var symbolPickerGroup: PaneID?

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
        .background(MissionKeyMonitor(isEditingText: { viewModel.renameTarget != nil }) { decision in
            switch decision {
            case .move(let direction): move(direction)
            case .open: activateSelection()
            case .pass: break
            }
        })
    }

    /// The one place the board is built, for drawing and for the keys alike.
    private func makeBoard(now: Date) -> (MissionBoard, RailSections)? {
        MissionBoard.make(viewModel: viewModel, board: boardNames, herdProgress: herdProgress, opensOlder: mode.opensOlder, opensUnknown: mode.opensUnknown, now: now)
    }

    private func resolveSelection(in board: MissionBoard) {
        let resolved = MissionSelection.resolve(mode.missionSelection, in: board.columns)
        if resolved != mode.missionSelection { mode.missionSelection = resolved }
    }

    private func lanes(_ board: MissionBoard, sections: RailSections, now: Date) -> some View {
        let host = renameHost(in: board)
        return HStack(alignment: .top, spacing: M.laneGap) {
            lane(title: "NEEDS YOU", count: board.needsYou.cardCount) {
                LaneMark(
                    theme: theme, front: board.needsYou.top.isEmpty ? nil : ShownStatus(.blocked),
                    back: board.needsYou.bottom.isEmpty ? nil : ShownStatus(.done), resting: ShownStatus(.blocked),
                    ground: theme.pane, size: M.laneDot
                )
            } body: {
                split(
                    board.needsYou, top: .blocked, bottom: .done, emptyMessage: "Nothing needs you",
                    sections: sections, now: now, renameHost: host
                )
            }
            lane(title: "WORKING", count: board.working.cardCount) {
                LaneMark(
                    theme: theme, front: board.working.top.isEmpty ? nil : ShownStatus(.working),
                    back: board.working.bottom.isEmpty ? nil : ShownStatus(.idle, backgroundWork: MissionSubgroup.background.rawValue),
                    resting: ShownStatus(.working), ground: theme.pane, size: M.laneDot
                )
            } body: {
                split(
                    board.working, top: .working, bottom: .background, emptyMessage: nil,
                    sections: sections, now: now, renameHost: host
                )
            }
            lane(title: "AT REST", count: board.atRestCount) {
                LaneMark(theme: theme, front: nil, back: nil, resting: ShownStatus(.idle), ground: theme.pane, size: M.laneDot)
            } body: {
                restScroll {
                    ForEach(board.atRest) { section in
                        VStack(alignment: .leading, spacing: M.cardGap) {
                            RestSectionLabel(theme: theme, section: section) {
                                if section.age == .unknown { mode.opensUnknown.toggle() } else { mode.opensOlder.toggle() }
                            }
                            if !section.isCollapsed {
                                ForEach(section.groups) { group($0, sections: sections, now: now, cooling: true, renameHost: host) }
                            }
                        }
                        .padding(.top, section.id == board.atRest.first?.id ? M.restFirstSectionGap : M.restSectionGap)
                    }
                }
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

    private func lane<Mark: View, Body: View>(
        title: String, count: Int, @ViewBuilder mark: () -> Mark, @ViewBuilder body: () -> Body
    ) -> some View {
        VStack(alignment: .leading, spacing: M.cardGap - M.laneScrollInset) {
            HStack(spacing: M.laneHeaderSpacing) {
                mark()
                Text(title).font(ChromeType.missionLaneTitle).tracking(1.28).foregroundStyle(theme.textLabel)
                Text("\(count)").font(ChromeType.missionLaneCount).foregroundStyle(theme.textLabel)
            }
            .padding(.horizontal, M.laneScrollInset)
            body()
        }
        .padding(M.lanePadding - M.laneScrollInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func split(
        _ lane: MissionSplitLane, top: MissionSubgroup, bottom: MissionSubgroup, emptyMessage: String?,
        sections: RailSections, now: Date, renameHost: PaneID?
    ) -> some View {
        SplitLaneBody(
            theme: theme, memory: MissionLaneMemory.of(viewModel),
            top: MissionSubgroupSlot(kind: top, cards: lane.top.flatMap(\.cards).map(\.paneID)),
            bottom: MissionSubgroupSlot(kind: bottom, cards: lane.bottom.flatMap(\.cards).map(\.paneID)),
            emptyMessage: emptyMessage, selection: mode.missionSelection
        ) { kind in
            let groups = kind == top ? lane.top : lane.bottom
            ForEach(groups) { each in
                group(
                    each, sections: sections, now: now, cooling: false, renameHost: renameHost,
                    floor: each.id == groups.first?.id ? kind : nil
                )
            }
        }
    }

    private func restScroll<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        let cards = content()
        return ScrollViewReader { reader in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: M.cardGap) { cards }
                    .padding(M.laneScrollInset)
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
    }

    /// A workspace's cards in one lane on the neutral wash its Arrange island
    /// wears. Its mark opens the symbol picker, and its menu is the rail's.
    /// `renameHost` is the one group, across every lane, that hosts the
    /// workspace's rename editor. `floor` names the subgroup this group
    /// leads, whose first card then reports where it ends.
    private func group(
        _ group: MissionGroup, sections: RailSections, now: Date, cooling: Bool, renameHost: PaneID?,
        floor: MissionSubgroup? = nil
    ) -> some View {
        let key = WorkspaceIdentityStore.key(for: group.workspaceID, sections: sections)
        let drawsSymbol = WorkspaceMark.drawsSymbol(key: key, logo: boardNames.logo, in: identityStore)
        let hostsRename = renameHost != nil && group.cards.first?.paneID == renameHost
        return VStack(alignment: .leading, spacing: M.cardGap) {
            HStack(spacing: M.groupLabelSpacing) {
                WorkspaceMark(theme: theme, key: key, size: M.groupMark, picking: pickerBinding(group))
                if hostsRename {
                    InlineRenameField(
                        theme: theme, font: ChromeType.missionGroupName,
                        initialText: viewModel.renameText(for: .workspace(group.workspaceID)),
                        accessibilityIdentifier: "flock.mission.group.rename.\(group.workspaceID.rawValue)",
                        onCommit: { text in Task { await viewModel.commitRename(text, for: .workspace(group.workspaceID)) } },
                        onCancel: { viewModel.cancelRename() }
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(group.name)
                        .font(ChromeType.missionGroupName)
                        // `textLabel` falls below AA on the workspace ground
                        // in several themes; `textDim` clears it in all.
                        .foregroundStyle(theme.textDim)
                        .lineLimit(1)
                }
            }
            ForEach(group.cards) { each in
                card(each, now: now, cooling: cooling)
                    .missionSubgroupFloor(each.id == group.cards.first?.id ? floor : nil, in: MissionLaneMemory.of(viewModel))
            }
        }
        .padding(M.groupPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .workspaceGround(theme, in: RoundedRectangle(cornerRadius: M.groupCornerRadius))
        .contentShape(RoundedRectangle(cornerRadius: M.groupCornerRadius))
        .workspaceMenu(
            viewModel: viewModel, workspace: group.workspaceID, key: key, changeSymbol: drawsSymbol ? { pick(group) } : nil
        )
    }

    /// The group that hosts the editor while a workspace is being renamed: the
    /// first one drawn, so a workspace with a group in several lanes shows one.
    private func renameHost(in board: MissionBoard) -> PaneID? {
        guard case .workspace(let workspace) = viewModel.renameTarget else { return nil }
        let drawn = board.needsYou.groups + board.working.groups + board.atRest.filter { !$0.isCollapsed }.flatMap(\.groups)
        return drawn.first { $0.workspaceID == workspace }?.cards.first?.paneID
    }

    private func pick(_ group: MissionGroup) {
        symbolPickerGroup = group.cards.first?.paneID
    }

    private func pickerBinding(_ group: MissionGroup) -> Binding<Bool> {
        let first = group.cards.first?.paneID
        return Binding(
            get: { first != nil && symbolPickerGroup == first },
            set: { open in
                if open { symbolPickerGroup = first } else if symbolPickerGroup == first { symbolPickerGroup = nil }
            }
        )
    }

    private func card(_ card: MissionCard, now: Date, cooling: Bool) -> some View {
        MissionCardView(
            theme: theme, card: card,
            place: bottomLine.active.text(viewModel.repoBranches.repoBranch(for: card.folder), workspace: card.workspaceName),
            segments: viewModel.statusHistory.segments(of: card.paneID, at: now), now: now,
            isSelected: mode.missionSelection == card.paneID, isCooling: cooling,
            rename: rename(card.paneID),
            activate: { open(card.paneID) }
        )
        .contextMenu {
            Button("Rename Pane") { viewModel.beginRename(.pane(card.paneID)) }
                .accessibilityIdentifier("flock.mission.card.rename")
            Divider()
            Button("Close Pane") { Task { await viewModel.closePane(card.paneID) } }
                .accessibilityIdentifier("flock.mission.card.close")
        }
        .matchedGeometryEffect(id: card.paneID, in: laneSpace)
        .id(card.paneID)
    }

    /// The card hosts the editor for its pane, or for the tab standing for it.
    private func rename(_ pane: PaneID) -> PaneRename? {
        let target = viewModel.renameTarget(for: .pane(pane))
        guard viewModel.renameTarget == target else { return nil }
        return PaneRename(
            initialText: viewModel.renameText(for: target),
            commit: { text in Task { await viewModel.commitRename(text, for: target) } },
            cancel: { viewModel.cancelRename() }
        )
    }

    private func move(_ direction: MissionSelection.Direction) {
        guard let (board, _) = makeBoard(now: viewModel.currentTime) else { return }
        let current = MissionSelection.resolve(mode.missionSelection, in: board.columns)
        guard current != nil else { return }
        // A selection that had gone stale lands on the first card rather than
        // moving away from it.
        mode.missionSelection = current == mode.missionSelection
            ? MissionSelection.move(current, direction, in: board.columns)
            : current
    }

    /// Opens the selected card only while it is drawn; a stale selection is
    /// replaced by the first card, which Return then opens.
    private func activateSelection() {
        guard let (board, _) = makeBoard(now: viewModel.currentTime),
              let pane = MissionSelection.resolve(mode.missionSelection, in: board.columns)
        else { return }
        guard pane == mode.missionSelection else {
            mode.missionSelection = pane
            return
        }
        open(pane)
    }

    private func open(_ pane: PaneID) {
        mode.missionSelection = pane
        JumpNavigator(viewModel: viewModel, drag: drag, mode: mode).open(pane: pane)
    }
}

/// One of At rest's time sections: its label, then a hairline to the lane's
/// edge. A foldable section's label is the disclosure that folds it.
struct RestSectionLabel: View {
    let theme: Theme
    let section: MissionRestSection
    var forced: ControlInteraction?
    let toggle: () -> Void

    private typealias M = ChromeMetrics.MissionControl

    var body: some View {
        HStack(spacing: M.restLabelSpacing) {
            if section.isCollapsible {
                GridControlButton(
                    theme: theme, shape: AnyShape(RoundedRectangle(cornerRadius: M.restDisclosureCornerRadius)),
                    restForeground: theme.textLabel, forced: forced, action: toggle
                ) {
                    HStack(spacing: M.restLabelSpacing) {
                        Image(systemName: section.isCollapsed ? "chevron.right" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                        title
                        Text("\(section.count)").font(ChromeType.missionRestSection)
                    }
                    .padding(.vertical, M.restDisclosureVerticalPadding)
                    .padding(.horizontal, M.restDisclosureHorizontalPadding)
                }
                .padding(.vertical, -M.restDisclosureVerticalPadding)
                .padding(.leading, -M.restDisclosureHorizontalPadding)
                .accessibilityIdentifier(section.age == .unknown ? "flock.mission.rest.unknown" : "flock.mission.rest.older")
            } else {
                title.foregroundStyle(theme.textLabel.opacity(M.restLabelOpacity))
            }
            Rectangle().fill(theme.rule).frame(height: ChromeMetrics.ruleWidth)
        }
    }

    private var title: some View {
        Text(section.age.title.uppercased())
            .font(ChromeType.missionRestSection)
            .tracking(M.restLabelTracking)
            .lineLimit(1)
            .fixedSize()
    }
}

/// Takes the arrows and Return while mission control is shown, before the
/// window's first responder sees them. A SwiftUI focus request is dropped
/// while an AppKit view holds first responder (`FirstResponderClaim`), and
/// mission control opens over a terminal that does: keyed on focus, the
/// arrows would reach the shell.
private struct MissionKeyMonitor: NSViewRepresentable {
    let isEditingText: () -> Bool
    let onDecision: (MissionKey.Decision) -> Void

    func makeNSView(context: Context) -> MonitorView { MonitorView() }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.isEditingText = isEditingText
        view.onDecision = onDecision
    }

    final class MonitorView: NSView {
        var isEditingText: () -> Bool = { false }
        var onDecision: (MissionKey.Decision) -> Void = { _ in }
        nonisolated(unsafe) private var monitor: Any?

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard let window else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === window else { return event }
                let flags = event.modifierFlags
                let decision = MissionKey.decide(
                    keyCode: event.keyCode, command: flags.contains(.command), control: flags.contains(.control),
                    option: flags.contains(.option), shift: flags.contains(.shift), editingText: self.isEditingText()
                )
                guard decision != .pass else { return event }
                self.onDecision(decision)
                return nil
            }
        }
    }
}

extension MissionBoard {
    /// The board as the app's stores hold it, for drawing and for the keys.
    @MainActor
    static func make(
        viewModel: SessionViewModel, board: BoardStore, herdProgress: HerdProgressStore, opensOlder: Bool,
        opensUnknown: Bool = false, now: Date
    ) -> (MissionBoard, RailSections)? {
        guard let model = viewModel.model,
              let sections = viewModel.railSections(board: board.names, herdProgress: herdProgress.progress)
        else { return nil }
        let missionBoard = MissionBoard(
            model: model, sections: sections, toasts: viewModel.attentionToasts,
            history: viewModel.statusHistory, backgroundWork: viewModel.backgroundWork, now: now, opensOlder: opensOlder,
            opensUnknown: opensUnknown, oneTitle: viewModel.oneTitle
        )
        return (missionBoard, sections)
    }

    /// One pane's card as `make`'s board draws it, with the sections its
    /// workspace key is read from.
    @MainActor
    static func card(
        _ pane: PaneID, viewModel: SessionViewModel, board: BoardStore, herdProgress: HerdProgressStore
    ) -> (card: MissionCard, sections: RailSections)? {
        guard let model = viewModel.model,
              let sections = viewModel.railSections(board: board.names, herdProgress: herdProgress.progress)
        else { return nil }
        let card = MissionBoard.card(
            pane, model: model, sections: sections, toasts: viewModel.attentionToasts, history: viewModel.statusHistory,
            backgroundWork: viewModel.backgroundWork, oneTitle: viewModel.oneTitle
        )
        return card.map { ($0, sections) }
    }
}
