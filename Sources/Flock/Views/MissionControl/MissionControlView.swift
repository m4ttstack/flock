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
    @Environment(HerdProgressStore.self) private var herdProgress
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// One space for every lane, so a card whose lane changes is the same
    /// view moving rather than one fading out and another in.
    @Namespace private var laneSpace
    @State private var symbolPickerTarget: SymbolPickerTarget?

    /// What was right-clicked to open the symbol picker, which anchors to it.
    private enum SymbolPickerTarget: Equatable {
        case group(WorkspaceID)
        case card(PaneID)
    }

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
        HStack(alignment: .top, spacing: M.laneGap) {
            lane(title: "NEEDS YOU", status: .blocked, count: board.needsYou.reduce(0) { $0 + $1.cards.count }) {
                if board.needsYou.isEmpty {
                    Text("Nothing needs you").font(ChromeType.missionEmpty).foregroundStyle(theme.textLabel)
                }
                ForEach(board.needsYou) { group($0, sections: sections, now: now, cooling: false) }
            }
            lane(title: "WORKING", status: .working, count: board.working.reduce(0) { $0 + $1.cards.count }) {
                ForEach(board.working) { group($0, sections: sections, now: now, cooling: false) }
            }
            lane(title: "AT REST", status: .idle, count: board.atRestCount) {
                ForEach(board.atRest) { section in
                    VStack(alignment: .leading, spacing: M.cardGap) {
                        RestSectionLabel(theme: theme, section: section) {
                            if section.age == .unknown { mode.opensUnknown.toggle() } else { mode.opensOlder.toggle() }
                        }
                        if !section.isCollapsed {
                            ForEach(section.groups) { group($0, sections: sections, now: now, cooling: true) }
                        }
                    }
                    .padding(.top, section.id == board.atRest.first?.id ? M.restFirstSectionGap : M.restSectionGap)
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

    private func lane<Content: View>(
        title: String, status: AgentStatus, count: Int, @ViewBuilder content: () -> Content
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
        }
        .padding(M.lanePadding - M.selectionInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// A workspace's cards in one lane on the neutral wash its Arrange island
    /// wears.
    private func group(_ group: MissionGroup, sections: RailSections, now: Date, cooling: Bool) -> some View {
        let key = WorkspaceIdentityStore.key(for: group.workspaceID, sections: sections)
        return VStack(alignment: .leading, spacing: M.cardGap) {
            HStack(spacing: M.groupLabelSpacing) {
                WorkspaceMark(theme: theme, key: key, size: M.groupMark)
                Text(group.name)
                    .font(ChromeType.missionGroupName)
                    .foregroundStyle(theme.textLabel)
                    .lineLimit(1)
            }
            .contextMenu { WorkspaceSymbolMenuItem(key: key) { symbolPickerTarget = .group(group.workspaceID) } }
            .workspaceSymbolPopover(theme: theme, key: key, isPresented: pickerBinding(.group(group.workspaceID)))
            ForEach(group.cards) { card($0, sections: sections, now: now, cooling: cooling) }
        }
        .padding(M.groupPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.workspaceWash, in: RoundedRectangle(cornerRadius: M.groupCornerRadius))
    }

    private func pickerBinding(_ target: SymbolPickerTarget) -> Binding<Bool> {
        Binding(
            get: { symbolPickerTarget == target },
            set: { if !$0, symbolPickerTarget == target { symbolPickerTarget = nil } }
        )
    }

    private func card(_ card: MissionCard, sections: RailSections, now: Date, cooling: Bool) -> some View {
        let cardKey = WorkspaceIdentityStore.key(for: card.workspaceID, sections: sections)
        return MissionCardView(
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
            WorkspaceSymbolMenuItem(key: cardKey) { symbolPickerTarget = .card(card.paneID) }
            Divider()
            Button("Close Pane") { Task { await viewModel.closePane(card.paneID) } }
                .accessibilityIdentifier("flock.mission.card.close")
        }
        .workspaceSymbolPopover(theme: theme, key: cardKey, isPresented: pickerBinding(.card(card.paneID)))
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
        guard let model = viewModel.model else { return nil }
        let sections = RailSections(model: model, board: board, herdProgress: herdProgress)
        let missionBoard = MissionBoard(
            model: model, sections: sections, toasts: viewModel.attentionToasts,
            history: viewModel.statusHistory, now: now, opensOlder: opensOlder,
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
        guard let model = viewModel.model else { return nil }
        let sections = RailSections(model: model, board: board, herdProgress: herdProgress)
        let card = MissionBoard.card(
            pane, model: model, sections: sections, toasts: viewModel.attentionToasts, history: viewModel.statusHistory,
            oneTitle: viewModel.oneTitle
        )
        return card.map { ($0, sections) }
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
