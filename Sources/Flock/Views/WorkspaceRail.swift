import AppKit
import FlockCore
import SwiftUI

/// The workspace sidebar: PINNED over WORKSPACES, each a heading over its
/// rows, with a rule on its trailing edge and the message dock at its foot.
/// Read-only mirror, selection/jump, and the workspace end of the drag layer.
struct WorkspaceRail: View {
    let theme: Theme
    let viewModel: SessionViewModel
    let onSelect: (WorkspaceID) -> Void

    @Environment(DragCoordinator.self) private var drag
    @Environment(RailWidthStore.self) private var railWidth
    @Environment(BoardStore.self) private var board
    @Environment(HerdProgressStore.self) private var herdProgress
    @Environment(WorkspaceIdentityStore.self) private var identity
    @State private var scrollPosition = ScrollPosition()
    @State private var symbolPickerRow: WorkspaceID?
    @State private var symbolPickerPin: PinID?
    @State private var renamingPin: PinID?
    @State private var railHeight: CGFloat?

    private struct PinnedSlot: Equatable {
        let id: PinID
        let workspace: WorkspaceID?
    }

    private var sections: RailSections? {
        viewModel.railSections(board: board.names, herdProgress: herdProgress.progress)
    }
    private var herdLabels: Set<String> {
        Set(viewModel.model?.workspaces.map(\.label).filter(HerdWorkspace.isHerd(label:)) ?? [])
    }
    /// The rows this rail lists, drags and reorders. Board's workspaces and
    /// herds are not among them: they sit in their own sections below.
    private var workspaces: [WorkspaceRecord] { sections?.workspaces ?? [] }
    private var hasPins: Bool { !(sections?.pinned.isEmpty ?? true) }
    private var pinnedSlots: [PinnedSlot] {
        sections?.pinned.map { PinnedSlot(id: $0.pin.id, workspace: $0.record?.workspaceID) } ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                // The headings are scroll content, so PINNED and WORKSPACES
                // scroll alike, and so is the horizontal padding, so the
                // viewport keeps the rail's full width for the insertion bar.
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: ChromeMetrics.Rail.rowGap) {
                        if let sections, !sections.pinned.isEmpty {
                            pinnedSection(sections)
                        }
                        // A heading over no rows says nothing, except while a
                        // live pin is carried and WORKSPACES is where it can go.
                        if !workspaces.isEmpty || drag.isDraggingLivePin {
                            workspacesHeading
                                .padding(.top, hasPins ? ChromeMetrics.RailSection.sectionGap : 0)
                        }
                        ForEach(Array(workspaces.enumerated()), id: \.element.workspaceID) { index, workspace in
                            workspaceRow(
                                workspace, markKey: workspace.workspaceID.rawValue,
                                displacement: drag.workspaceDisplacement(at: index) + drag.pinnedGrowth,
                                isGhosted: drag.isDragging(workspace: workspace.workspaceID),
                                joinsSelection: true,
                                reportFrame: { drag.setWorkspaceFrame($0, for: workspace.workspaceID) },
                                gesture: rowDrag(workspace)
                            )
                        }
                        if let sections, !sections.board.isEmpty {
                            BoardSection(
                                theme: theme, workspaces: sections.board, logo: board.logo,
                                paneCount: { viewModel.paneCount(for: $0) },
                                selectedWorkspaceID: viewModel.selectedWorkspaceID,
                                showsFill: { drag.showsWorkspaceFill($0, isCurrent: $0 == viewModel.selectedWorkspaceID) },
                                onClick: handleSectionRowClick
                            )
                            .offset(y: drag.pinnedGrowth + drag.workspacesGrowth)
                        }
                        if let sections, let summary = sections.herdSummary {
                            HerdsSection(
                                theme: theme, herds: sections.herds, summary: summary,
                                selectedWorkspaceID: viewModel.selectedWorkspaceID,
                                showsFill: { drag.showsWorkspaceFill($0, isCurrent: $0 == viewModel.selectedWorkspaceID) },
                                onClick: handleSectionRowClick
                            )
                            .offset(y: drag.pinnedGrowth + drag.workspacesGrowth)
                        }
                        // Real content, filling whatever height the rows
                        // leave inside the viewport: a `ScrollView` bridges to
                        // an `NSScrollView`, whose clip view claims hit
                        // testing across its own bounds, so a right-click
                        // past where a shorter document actually ends never
                        // reaches a layer drawn behind the scroll view at
                        // all. herdr draws a "+" of its own in the sidebar;
                        // flock's equivalent is this zone plus File > New
                        // Workspace, so the resting chrome carries no control
                        // the design never drew.
                        newWorkspaceZone
                    }
                    .animation(.easeOut(duration: DragVisuals.reshuffleDuration), value: drag.pinnedGrowth)
                    .animation(.easeOut(duration: DragVisuals.reshuffleDuration), value: drag.workspacesGrowth)
                    .padding(.vertical, ChromeMetrics.Rail.verticalPadding)
                    .padding(.horizontal, ChromeMetrics.Rail.horizontalPadding)
                    .frame(width: railWidth.width, alignment: .leading)
                    // Gives the row stack a concrete height to allocate
                    // rather than the unbounded one a `ScrollView` proposes to
                    // its content: only that turns `newWorkspaceZone`'s own
                    // `maxHeight: .infinity` into a real fill of the leftover
                    // space rather than the near-zero share SwiftUI gives a
                    // flexible child under an unbounded proposal.
                    .frame(minHeight: drag.railViewport?.height, alignment: .top)
                    .coordinateSpace(.named(DragSpace.railContent))
                    .reportsDragFrame { drag.setRailContentOrigin($0.origin) }
                }
                .scrollIndicators(.never)
                .scrollBounceBehavior(.basedOnSize, axes: .vertical)
                .scrollPosition($scrollPosition)
                .reportsScrollExtent(.vertical) { drag.setRailScroll(offset: $0, maximumOffset: $1) }
                .frame(maxHeight: .infinity)
                .reportsDragFrame { drag.railViewport = $0 }
                .onAppear { drag.railScroller = { y in scrollPosition.scrollTo(y: y) } }
            }
            .frame(width: railWidth.width)
            .padding(.trailing, ChromeMetrics.ruleWidth)
            // The lists alone, rule included and dock excluded: every rail
            // drop target and the new-workspace zone are measured against
            // this frame, so a card can never be dropped on or read as free
            // rail space below the last row.
            .reportsDragFrame { drag.railFrame = $0 }
            MessageDock(theme: theme, viewModel: viewModel, placement: .rail, railHeight: railHeight)
                .frame(width: railWidth.width)
                .padding(.trailing, ChromeMetrics.ruleWidth)
        }
        // One rule down the whole edge, the dock's stretch included, so the
        // edge never breaks where the lists end.
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(theme.rule)
                .frame(width: ChromeMetrics.ruleWidth)
        }
        // Inside the rail's own bounds rather than straddling the rule: an
        // overlay drawn past its parent's edge is not reliably hit-tested
        // there, and a band that reached into the canvas would sit over the
        // pane chrome the canvas draws at its own edge.
        .overlay(alignment: .trailing) { resizeHandle }
        .boundedBackground(theme.chrome)
        .onGeometryChange(for: CGFloat.self, of: \.size.height) { railHeight = $0 }
        .onAppear {
            drag.setWorkspaceOrder(workspaces.map(\.workspaceID))
            setPinnedOrder(pinnedSlots)
            if let sections { identity.refresh(sections) }
        }
        .onChange(of: workspaces.map(\.workspaceID)) { _, ids in
            drag.setWorkspaceOrder(ids)
            if let sections { identity.refresh(sections) }
        }
        .onChange(of: pinnedSlots) { _, slots in
            setPinnedOrder(slots)
            if let renamingPin, let slot = slots.first(where: { $0.id == renamingPin }) {
                // A double click whose reopen landed after its second click:
                // the rename it asked for moves to the workspace it opened.
                if let workspace = slot.workspace {
                    self.renamingPin = nil
                    viewModel.beginRename(.workspace(workspace))
                }
            } else if renamingPin != nil {
                renamingPin = nil
            }
            if let sections { identity.refresh(sections) }
        }
        // Keyed on the herds shown, so a herd arriving is asked about at
        // once rather than at the next tick, and a rail with none stops
        // asking.
        .task(id: herdLabels) {
            await herdProgress.refresh(labels: herdLabels)
            while !herdLabels.isEmpty, !Task.isCancelled {
                try? await Task.sleep(for: HerdProgressStore.interval)
                await herdProgress.refresh(labels: herdLabels)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await herdProgress.refresh(labels: herdLabels) }
        }
    }

    /// Its bottom padding and the stack's row gap together make
    /// `headingToFirstRow`.
    private func railHeading(_ title: String) -> some View {
        Text(title)
            .font(ChromeType.railHeading)
            .tracking(ChromeType.railHeadingTracking)
            .foregroundStyle(theme.textLabel)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, ChromeMetrics.Rail.headingToFirstRow - ChromeMetrics.Rail.rowGap)
    }

    /// Offset inside its frame report, so the frame published is the
    /// heading's resting place.
    private var workspacesHeading: some View {
        railHeading("WORKSPACES")
            .offset(y: drag.pinnedGrowth)
            .reportsFrame(in: DragSpace.railContent) { drag.setWorkspacesHeading($0) }
            .onDisappear { drag.setWorkspacesHeading(nil) }
    }

    /// Its region is reported whole, heading included, so a drop on the
    /// heading or between rows still lands in PINNED.
    private func pinnedSection(_ sections: RailSections) -> some View {
        VStack(alignment: .leading, spacing: ChromeMetrics.Rail.rowGap) {
            railHeading("PINNED")
            ForEach(Array(sections.pinned.enumerated()), id: \.element.pin.id) { index, row in
                pinnedRow(row, index: index)
            }
        }
        .reportsFrame(in: DragSpace.railContent) { drag.setPinnedRegion($0) }
    }

    @ViewBuilder
    private func pinnedRow(_ row: RailSections.PinnedRow, index: Int) -> some View {
        let report: (CGRect) -> Void = { drag.setPinFrame($0, for: row.pin.id, workspace: row.record?.workspaceID) }
        if let workspace = row.record {
            workspaceRow(
                workspace, markKey: row.pin.identityKey,
                displacement: drag.pinDisplacement(at: index),
                isGhosted: drag.isDragging(pin: row.pin.id),
                joinsSelection: false,
                reportFrame: report,
                gesture: pinDrag(row.pin)
            )
            .popover(isPresented: folderAskBinding(row.pin.id), arrowEdge: .trailing) {
                if let ask = viewModel.pinFolderAsk, ask.pin == row.pin.id {
                    PinFolderPopover(
                        theme: theme, name: row.pin.name, ask: ask,
                        onChoose: { viewModel.answerPinFolder(row.pin.id, with: $0) },
                        onOther: { chooseOtherFolder(for: row.pin) }
                    )
                }
            }
        } else {
            emptyPinRow(row.pin, index: index, reportFrame: report)
        }
    }

    private func workspaceRow<G: Gesture>(
        _ workspace: WorkspaceRecord, markKey: String, displacement: CGFloat, isGhosted: Bool, joinsSelection: Bool,
        reportFrame: @escaping (CGRect) -> Void, gesture: G
    ) -> some View {
        let isRenaming = viewModel.renameTarget == .workspace(workspace.workspaceID)
        return WorkspaceRow(
            theme: theme,
            workspace: workspace,
            paneCount: viewModel.paneCount(for: workspace.workspaceID),
            isSelected: workspace.workspaceID == viewModel.shownWorkspaceID,
            isRenaming: isRenaming,
            markKey: markKey,
            pickingSymbol: pickerBinding(workspace.workspaceID),
            renameText: viewModel.renameText(for: .workspace(workspace.workspaceID)),
            onCommitRename: { text in
                Task { await viewModel.commitRename(text, for: .workspace(workspace.workspaceID)) }
            },
            onCancelRename: { viewModel.cancelRename() },
            showsFill: drag.showsWorkspaceFill(
                workspace.workspaceID, isCurrent: workspace.workspaceID == viewModel.shownWorkspaceID
            ),
            displacement: displacement,
            isGhosted: isGhosted,
            isBackground: viewModel.shownStatus(of: workspace).isBackground
        )
        // Outside the row, which offsets its own content: the frame published
        // here is the row's resting place, which is what the insertion index
        // is measured against.
        .reportsFrame(in: DragSpace.railContent, reportFrame)
        // A container, so the identifier below names the whole row and the
        // controls inside it keep their own. Without it SwiftUI folds the row
        // into its name text: the row reads as a label a third of its width,
        // and its rename editor is not reachable at all.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("flock.rail.workspace.\(workspace.workspaceID.rawValue)")
        // ONE tap gesture, which is what keeps a plain click instant: a
        // `count: 2` sibling for the rename would make this one wait out the
        // system's double-click interval before it could fire at all
        // (`ChromeRowClick`).
        .onTapGesture { handleClick(on: workspace.workspaceID, joinsSelection: joinsSelection) }
        // Disarmed while this row is being renamed: a press inside the field
        // must reach the text, not start a drag.
        .simultaneousGesture(gesture, including: isRenaming ? .subviews : .all)
        .workspaceMenu(
            viewModel: viewModel, workspace: workspace.workspaceID, key: markKey,
            changeSymbol: { symbolPickerRow = workspace.workspaceID }
        )
    }

    private func emptyPinRow(_ pin: PinnedWorkspace, index: Int, reportFrame: @escaping (CGRect) -> Void) -> some View {
        let isRenaming = renamingPin == pin.id
        return EmptyPinRow(
            theme: theme,
            pin: pin,
            isSelected: viewModel.shownEmptyPin == pin.id,
            isRenaming: isRenaming,
            pickingSymbol: pinPickerBinding(pin.id),
            onCommitRename: { text in
                viewModel.renamePin(pin.id, to: text)
                renamingPin = nil
            },
            onCancelRename: { renamingPin = nil },
            displacement: drag.pinDisplacement(at: index),
            isGhosted: drag.isDragging(pin: pin.id)
        )
        .reportsFrame(in: DragSpace.railContent, reportFrame)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("flock.rail.pin.\(pin.id.rawValue)")
        .onTapGesture { handleEmptyPinClick(pin.id) }
        .simultaneousGesture(pinDrag(pin), including: isRenaming ? .subviews : .all)
        .emptyPinMenu(
            viewModel: viewModel, pin: pin, beginRename: { renamingPin = pin.id }, changeSymbol: { symbolPickerPin = pin.id }
        )
    }

    /// Selection on the first click, the rename editor on the second. A row
    /// the user double-clicks is therefore selected on the way into the
    /// editor, which is the price of never holding a plain click back to find
    /// out whether a second one is coming. A pinned row joins no Cmd+click
    /// selection: that selection is dragged as a block within WORKSPACES.
    private func handleClick(on workspace: WorkspaceID, joinsSelection: Bool = true) {
        switch NSEvent.chromeRowClick(NSApp.currentEvent) {
        case .select:
            let commandHeld = joinsSelection && NSEvent.modifierFlags.contains(.command)
            if drag.clickWorkspace(workspace, commandHeld: commandHeld, current: viewModel.shownWorkspaceID) {
                onSelect(workspace)
            }
        case .beginRename:
            viewModel.beginRename(.workspace(workspace))
        case .ignore:
            break
        }
    }

    /// Shows the pin on the first click and renames on the second, by the
    /// rule `handleClick` follows. Showing opens nothing.
    private func handleEmptyPinClick(_ pin: PinID) {
        switch NSEvent.chromeRowClick(NSApp.currentEvent) {
        case .select:
            viewModel.show(emptyPin: pin)
        case .beginRename:
            renamingPin = pin
        case .ignore:
            break
        }
    }

    /// Dismissing the question keeps the folder the pin already holds.
    private func folderAskBinding(_ pin: PinID) -> Binding<Bool> {
        Binding(
            get: { viewModel.pinAwaitingFolder == pin },
            set: { shown in if !shown { viewModel.answerPinFolder(pin, with: nil) } }
        )
    }

    /// After the popover has gone: Finder's panel is modal, and the popover
    /// must not sit under it.
    private func chooseOtherFolder(for pin: PinnedWorkspace) {
        let current = viewModel.pins.pin(pin.id)?.folder ?? pin.folder
        viewModel.answerPinFolder(pin.id, with: nil)
        DispatchQueue.main.async {
            if let folder = FolderPanel.choose(current: current, message: "Where should \"\(pin.name)\" open?") {
                viewModel.setPinFolder(pin.id, to: folder)
            }
        }
    }

    private func setPinnedOrder(_ slots: [PinnedSlot]) {
        drag.setPinnedOrder(
            slots.map(\.id),
            workspaces: Dictionary(uniqueKeysWithValues: slots.compactMap { slot in slot.workspace.map { (slot.id, $0) } })
        )
    }

    /// A Board or herd row selects and does nothing else: its label is
    /// board's or rt's, so it offers no rename, and it joins no Cmd+click
    /// selection because neither section is reordered from the rail.
    private func handleSectionRowClick(_ workspace: WorkspaceID) {
        guard case .select = NSEvent.chromeRowClick(NSApp.currentEvent) else { return }
        if drag.clickWorkspace(workspace, commandHeld: false, current: viewModel.selectedWorkspaceID) {
            onSelect(workspace)
        }
    }

    /// The rail's trailing edge, grabbable. It draws nothing: the rule is
    /// already the edge, and the resize cursor is how macOS says an edge
    /// moves. Withheld during a pane drag, which owns the closed hand for its
    /// whole duration, exactly as the canvas's dividers are.
    private var resizeHandle: some View {
        Color.clear
            .frame(width: ChromeMetrics.Rail.resizeGrabWidth)
            .contentShape(Rectangle())
            .pointerStyle(drag.isPaneDragInFlight ? nil : .columnResize)
            .gesture(resizeGesture)
            .accessibilityLabel("Sidebar width")
            .accessibilityIdentifier("flock.rail.resize")
    }

    /// Read in the drag space, whose origin is the window's own leading edge,
    /// so the pointer's x IS the width being asked for and nothing has to be
    /// reconstructed from the rail rect this very gesture moves.
    ///
    /// The release carries its own point: motion is coalesced and can be
    /// outrun, so the last position `onChanged` reported is not where the
    /// hand finished. `RailWidthStore` is what clamps and remembers it.
    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(DragSpace.name))
            .onChanged { railWidth.dragged(to: $0.location.x) }
            .onEnded { railWidth.released(at: $0.location.x) }
    }

    /// A right-click on rail space no row occupies offers New Workspace by
    /// name; File > New Workspace is the other route. No plain-click gesture
    /// here: the zone is a large target, and a bare click on it is not a
    /// deliberate way to create a workspace. Invisible by construction, so it
    /// costs the resting chrome nothing. A row of its own height sits above
    /// this zone in the row stack rather than overlapping it, so a
    /// right-click that lands on a row never reaches here. Also the drag
    /// target for dropping a pane to create a workspace from it
    /// (`flock.rail.newWorkspace`), unrelated to the context menu.
    private var newWorkspaceZone: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .accessibilityIdentifier("flock.rail.newWorkspace")
            .contextMenu {
                ForEach(RailMenuModel.entries(), id: \.accessibilityIdentifier) { entry in
                    Button(entry.label) {
                        Task { await entry.action.perform(on: viewModel) }
                    }
                    .accessibilityIdentifier(entry.accessibilityIdentifier)
                }
            }
    }

    private func pickerBinding(_ workspace: WorkspaceID) -> Binding<Bool> {
        Binding(
            get: { symbolPickerRow == workspace },
            set: { open in
                if open { symbolPickerRow = workspace } else if symbolPickerRow == workspace { symbolPickerRow = nil }
            }
        )
    }

    private func pinPickerBinding(_ pin: PinID) -> Binding<Bool> {
        Binding(
            get: { symbolPickerPin == pin },
            set: { open in
                if open { symbolPickerPin = pin } else if symbolPickerPin == pin { symbolPickerPin = nil }
            }
        )
    }

    /// Starts the drag and nothing else: `DragCoordinator` drives it from
    /// there, off window-level monitors, so no per-row latch can be left
    /// behind by a rail that is rebuilt mid-drag.
    private func rowDrag(_ workspace: WorkspaceRecord) -> some Gesture {
        DragGesture(minimumDistance: DragThreshold.movement, coordinateSpace: .named(DragSpace.name))
            .onChanged { value in
                let subject = drag.workspaceDragSubject(pressing: workspace.workspaceID)
                let title = if case .workspaces(let block) = subject { "\(block.count) workspaces" } else { workspace.label }
                drag.beginIfIdle(
                    subject,
                    ghost: DragCoordinator.Ghost(
                        title: title,
                        symbol: "square.grid.2x2",
                        originSize: drag.workspaceFrames.first { $0.id == workspace.workspaceID }?.frame.size ?? .zero
                    ),
                    at: value.startLocation
                )
            }
    }

    private func pinDrag(_ pin: PinnedWorkspace) -> some Gesture {
        DragGesture(minimumDistance: DragThreshold.movement, coordinateSpace: .named(DragSpace.name))
            .onChanged { value in
                drag.beginIfIdle(
                    drag.pinDragSubject(pin.id),
                    ghost: DragCoordinator.Ghost(
                        title: pin.name,
                        symbol: "square.grid.2x2",
                        originSize: drag.pinFrames.first { $0.id == pin.id }?.frame.size ?? .zero
                    ),
                    at: value.startLocation
                )
            }
    }
}

struct WorkspaceRow: View {
    let theme: Theme
    let workspace: WorkspaceRecord
    let paneCount: Int
    let isSelected: Bool
    var isRenaming = false
    /// The workspace's symbol key, drawn before the name; nil draws none, as
    /// for Board's rows, which their section's logo marks.
    var markKey: String?
    var pickingSymbol: Binding<Bool>?
    var renameText = ""
    var onCommitRename: (String) -> Void = { _ in }
    var onCancelRename: () -> Void = {}
    /// The selection fill alone. The accent bar and weight always mark
    /// herdr's selected workspace; the fill follows the Cmd+click selection
    /// whenever one exists.
    var showsFill = false
    /// How far this row slides to open the insertion gap.
    var displacement: CGFloat = 0
    /// The row this drag started from, left in place and faded.
    var isGhosted = false
    var isBackground = false

    var body: some View {
        HStack(spacing: ChromeMetrics.WorkspaceRow.spacing) {
            // The dot always means status, on the selected row too: selection
            // is already carried by the row fill and the heavier name, and a
            // row that swapped its status for an accent was the one row whose
            // agent you could not see.
            StatusDot(
                status: workspace.agentStatus, theme: theme, size: ChromeMetrics.WorkspaceRow.statusDot, isBackground: isBackground
            )
            if let markKey {
                WorkspaceMark(theme: theme, key: markKey, size: ChromeMetrics.WorkspaceRow.mark, picking: pickingSymbol)
            }
            if isRenaming {
                InlineRenameField(
                    theme: theme, font: ChromeType.workspaceName(selected: isSelected), initialText: renameText,
                    accessibilityIdentifier: "flock.rail.rename.\(workspace.workspaceID.rawValue)",
                    onCommit: onCommitRename, onCancel: onCancelRename
                )
            } else {
                Text(workspace.label)
                    .font(ChromeType.workspaceName(selected: isSelected))
                    .foregroundStyle(isSelected ? theme.textStrong : theme.textDim)
                    .lineLimit(1)
                Spacer(minLength: ChromeMetrics.WorkspaceRow.countMinimumGap)
                Text("\(paneCount)")
                    .font(ChromeType.workspaceCount)
                    .foregroundStyle(theme.textLabel)
            }
        }
        .modifier(RailRowChrome(theme: theme, showsFill: showsFill))
        .opacity(isGhosted ? DragVisuals.originOpacity : 1)
        .offset(y: displacement)
        .animation(.easeOut(duration: DragVisuals.reshuffleDuration), value: displacement)
        .animation(.easeOut(duration: 0.12), value: isGhosted)
    }
}

/// A pin with nothing open: a blank where the status dot sits, since the dot
/// only ever means status and nothing runs here, then the symbol and name
/// dimmed, and no count.
struct EmptyPinRow: View {
    let theme: Theme
    let pin: PinnedWorkspace
    var isSelected = false
    var isRenaming = false
    var pickingSymbol: Binding<Bool>?
    var onCommitRename: (String) -> Void = { _ in }
    var onCancelRename: () -> Void = {}
    var displacement: CGFloat = 0
    var isGhosted = false

    var body: some View {
        HStack(spacing: ChromeMetrics.WorkspaceRow.spacing) {
            Color.clear.frame(width: ChromeMetrics.WorkspaceRow.statusDot, height: ChromeMetrics.WorkspaceRow.statusDot)
            WorkspaceMark(
                theme: theme, key: pin.identityKey, size: ChromeMetrics.WorkspaceRow.mark, picking: pickingSymbol,
                foreground: theme.textLabel.opacity(ChromeMetrics.WorkspaceRow.emptyPinOpacity)
            )
            if isRenaming {
                InlineRenameField(
                    theme: theme, font: ChromeType.workspaceName(selected: false), initialText: pin.name,
                    accessibilityIdentifier: "flock.rail.pin.rename.\(pin.id.rawValue)",
                    onCommit: onCommitRename, onCancel: onCancelRename
                )
            } else {
                Text(pin.name)
                    .font(ChromeType.workspaceName(selected: false))
                    .foregroundStyle(theme.textLabel.opacity(ChromeMetrics.WorkspaceRow.emptyPinOpacity))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .modifier(RailRowChrome(theme: theme, showsFill: isSelected))
        .opacity(isGhosted ? DragVisuals.originOpacity : 1)
        .offset(y: displacement)
        .animation(.easeOut(duration: DragVisuals.reshuffleDuration), value: displacement)
        .animation(.easeOut(duration: 0.12), value: isGhosted)
    }
}
