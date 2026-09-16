import AppKit
import PaddockCore
import SwiftUI

/// The workspace sidebar: a heading over one row per workspace, with a rule on
/// its trailing edge. Read-only mirror, selection/jump, and the workspace end
/// of the drag layer.
struct WorkspaceRail: View {
    let theme: Theme
    let viewModel: SessionViewModel
    let onSelect: (WorkspaceID) -> Void

    @Environment(DragCoordinator.self) private var drag
    @State private var scrollPosition = ScrollPosition()
    @State private var hoveredWorkspaceID: WorkspaceID?

    private var workspaces: [WorkspaceRecord] { viewModel.model?.workspaces ?? [] }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("WORKSPACES")
                    .font(ChromeType.railHeading)
                    .tracking(ChromeType.railHeadingTracking)
                    .foregroundStyle(theme.textLabel)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Centered on the heading text and overlaid, so the
                    // button's box can never move the heading or the rows
                    // under it however large it grows.
                    .overlay(alignment: .trailing) { AllWorkspacesButton(theme: theme) }
                    .padding(.top, ChromeMetrics.Rail.verticalPadding)
                    .padding(.horizontal, ChromeMetrics.Rail.horizontalPadding)
                // Only the rows scroll. The gap below the heading is scroll
                // content, so rows scroll up to the heading's edge, and the
                // horizontal padding is too, so the viewport keeps the rail's
                // full width for the insertion bar.
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: ChromeMetrics.Rail.rowGap) {
                        ForEach(Array(workspaces.enumerated()), id: \.element.workspaceID) { index, workspace in
                            let isRenaming = viewModel.renameTarget == .workspace(workspace.workspaceID)
                            WorkspaceRow(
                                theme: theme,
                                workspace: workspace,
                                paneCount: viewModel.paneCount(for: workspace.workspaceID),
                                isSelected: workspace.workspaceID == viewModel.selectedWorkspaceID,
                                isRenaming: isRenaming,
                                showsClose: hoveredWorkspaceID == workspace.workspaceID && !isRenaming,
                                renameText: viewModel.renameText(for: .workspace(workspace.workspaceID)),
                                onCommitRename: { text in
                                    Task { await viewModel.commitRename(text, for: .workspace(workspace.workspaceID)) }
                                },
                                onCancelRename: { viewModel.cancelRename() },
                                onClose: { Task { await viewModel.closeWorkspace(workspace.workspaceID) } },
                                showsFill: drag.showsWorkspaceFill(
                                    workspace.workspaceID, isCurrent: workspace.workspaceID == viewModel.selectedWorkspaceID
                                ),
                                displacement: drag.workspaceDisplacement(at: index),
                                isGhosted: drag.isDragging(workspace: workspace.workspaceID)
                            )
                            // Outside the row, which offsets its own content: the
                            // frame published here is the row's resting place,
                            // which is what the insertion index is measured
                            // against.
                            .reportsFrame(in: DragSpace.railContent) { drag.setWorkspaceFrame($0, for: workspace.workspaceID) }
                            .accessibilityIdentifier("paddock.rail.workspace.\(workspace.workspaceID.rawValue)")
                            .onHover { hovering in
                                hoveredWorkspaceID = hovering
                                    ? workspace.workspaceID
                                    : (hoveredWorkspaceID == workspace.workspaceID ? nil : hoveredWorkspaceID)
                            }
                            // Both guarded: SwiftUI's tap gesture on macOS
                            // fires for the secondary button too, so without
                            // this a right-click moves the rail's selection
                            // and two of them open the rename editor, on top
                            // of the context menu they were asking for.
                            .onTapGesture(count: 2) {
                                guard !NSEvent.isSecondaryButtonEvent(NSApp.currentEvent) else { return }
                                viewModel.beginRename(.workspace(workspace.workspaceID))
                            }
                            .onTapGesture {
                                guard !NSEvent.isSecondaryButtonEvent(NSApp.currentEvent) else { return }
                                let commandHeld = NSEvent.modifierFlags.contains(.command)
                                if drag.clickWorkspace(workspace.workspaceID, commandHeld: commandHeld, current: viewModel.selectedWorkspaceID) {
                                    onSelect(workspace.workspaceID)
                                }
                            }
                            // Disarmed while this row is being renamed: a press
                            // inside the field must reach the text, not start a
                            // drag.
                            .simultaneousGesture(rowDrag(workspace), including: isRenaming ? .subviews : .all)
                            .contextMenu {
                                ForEach(workspaceMenuEntries(for: workspace.workspaceID), id: \.accessibilityIdentifier) { entry in
                                    Button(entry.label) {
                                        Task { await entry.action.perform(workspaceID: workspace.workspaceID, on: viewModel) }
                                    }
                                    .accessibilityIdentifier(entry.accessibilityIdentifier)
                                }
                            }
                        }
                    }
                    .padding(.top, ChromeMetrics.Rail.headingToFirstRow)
                    .padding(.bottom, ChromeMetrics.Rail.verticalPadding)
                    .padding(.horizontal, ChromeMetrics.Rail.horizontalPadding)
                    .frame(width: ChromeMetrics.Rail.width, alignment: .leading)
                    .coordinateSpace(.named(DragSpace.railContent))
                    .reportsDragFrame { drag.setRailContentOrigin($0.origin) }
                }
                .scrollIndicators(.never)
                .scrollBounceBehavior(.basedOnSize, axes: .vertical)
                .scrollPosition($scrollPosition)
                .reportsScrollExtent(.vertical) { drag.setRailScroll(offset: $0, maximumOffset: $1) }
                .frame(maxHeight: .infinity)
                .reportsDragFrame { drag.railViewport = $0 }
                // Behind the rows, so only rail space no row occupies reaches
                // it. herdr draws a "+" of its own in the sidebar; paddock's
                // equivalent is this zone plus File > New Workspace, so the
                // resting chrome carries no control the design never drew.
                .background { newWorkspaceZone }
                .onAppear { drag.railScroller = { y in scrollPosition.scrollTo(y: y) } }
            }
            .frame(width: ChromeMetrics.Rail.width)
            Rectangle()
                .fill(theme.rule)
                .frame(width: ChromeMetrics.ruleWidth)
        }
        .boundedBackground(theme.chrome)
        .reportsDragFrame { drag.railFrame = $0 }
        .onAppear { drag.setWorkspaceOrder(workspaces.map(\.workspaceID)) }
        .onChange(of: workspaces.map(\.workspaceID)) { _, ids in drag.setWorkspaceOrder(ids) }
    }

    /// A plain click on rail space no row occupies creates a workspace.
    /// Invisible by construction, so it costs the resting chrome nothing.
    private var newWorkspaceZone: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture {
                guard !NSEvent.isSecondaryButtonEvent(NSApp.currentEvent) else { return }
                Task { await viewModel.createWorkspace() }
            }
            .accessibilityIdentifier("paddock.rail.newWorkspace")
    }

    private func workspaceMenuEntries(for workspace: WorkspaceID) -> [ChromeMenuEntry<WorkspaceMenuAction>] {
        guard let model = viewModel.model else { return [] }
        return WorkspaceMenuModel.entries(for: workspace, model: model)
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
}

/// The way into the All Workspaces grid that does not need the menu. The way
/// back is Esc: the grid covers this rail while it is shown.
private struct AllWorkspacesButton: View {
    let theme: Theme

    @Environment(DragCoordinator.self) private var drag
    @State private var isHovering = false

    var body: some View {
        Button {
            drag.toggleGrid()
        } label: {
            Image(systemName: "square.grid.2x2")
                .font(ChromeType.railHeadingSymbol)
        }
        .buttonStyle(HeadingButtonStyle(theme: theme, isHovering: isHovering))
        .onHover { isHovering = $0 }
        .help("All workspaces")
        .accessibilityIdentifier("paddock.rail.allWorkspaces")
    }
}

/// The selected-tab block behind the glyph, appearing on hover and taking a
/// wash of accent while the press is held.
private struct HeadingButtonStyle: ButtonStyle {
    let theme: Theme
    let isHovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        let lit = isHovering || configuration.isPressed
        return configuration.label
            .foregroundStyle(lit ? theme.textStrong : theme.textLabel)
            .frame(width: ChromeMetrics.Rail.headingButtonSize, height: ChromeMetrics.Rail.headingButtonSize)
            .background(
                RoundedRectangle(cornerRadius: ChromeMetrics.Rail.headingButtonCornerRadius)
                    .fill(theme.selection)
                    .overlay(
                        RoundedRectangle(cornerRadius: ChromeMetrics.Rail.headingButtonCornerRadius)
                            .fill(theme.accent)
                            .opacity(configuration.isPressed ? ChromeMetrics.Rail.headingButtonPressedAccent : 0)
                    )
                    .opacity(lit ? 1 : 0)
            )
            .contentShape(Rectangle())
            .animation(.easeOut(duration: DragVisuals.previewCrossfadeDuration), value: lit)
    }
}

private struct WorkspaceRow: View {
    let theme: Theme
    let workspace: WorkspaceRecord
    let paneCount: Int
    let isSelected: Bool
    var isRenaming = false
    /// The hover-reveal close: laid out on every row either way, so a row
    /// never reflows as the pointer crosses it.
    var showsClose = false
    var renameText = ""
    var onCommitRename: (String) -> Void = { _ in }
    var onCancelRename: () -> Void = {}
    var onClose: () -> Void = {}
    /// The selection fill alone. The accent bar and weight always mark
    /// herdr's selected workspace; the fill follows the Cmd+click selection
    /// whenever one exists.
    var showsFill = false
    /// How far this row slides to open the insertion gap.
    var displacement: CGFloat = 0
    /// The row this drag started from, left in place and faded.
    var isGhosted = false

    var body: some View {
        HStack(spacing: ChromeMetrics.WorkspaceRow.spacing) {
            // Present on every row so names stay aligned, clear when there is
            // nothing to mark.
            RoundedRectangle(cornerRadius: ChromeMetrics.WorkspaceRow.indicatorSize.width / 2)
                .fill(indicatorColor ?? .clear)
                .frame(width: ChromeMetrics.WorkspaceRow.indicatorSize.width, height: ChromeMetrics.WorkspaceRow.indicatorSize.height)
            if isRenaming {
                InlineRenameField(
                    theme: theme, font: ChromeType.workspaceName(selected: isSelected), initialText: renameText,
                    accessibilityIdentifier: "paddock.rail.rename.\(workspace.workspaceID.rawValue)",
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
        .overlay(alignment: .trailing) {
            HoverCloseButton(
                theme: theme, isRevealed: showsClose, help: "Close workspace",
                accessibilityIdentifier: "paddock.rail.close.\(workspace.workspaceID.rawValue)", action: onClose
            )
        }
        // Fixed rather than taken from the label's line height, which varies
        // with face and size, so rows keep a whole-point pitch.
        .frame(height: ChromeMetrics.WorkspaceRow.contentHeight)
        .padding(.vertical, ChromeMetrics.WorkspaceRow.verticalPadding)
        .padding(.horizontal, ChromeMetrics.WorkspaceRow.horizontalPadding)
        .background(
            RoundedRectangle(cornerRadius: ChromeMetrics.WorkspaceRow.cornerRadius)
                .fill(theme.selection)
                .opacity(showsFill ? 1 : 0)
        )
        .contentShape(Rectangle())
        .opacity(isGhosted ? DragVisuals.originOpacity : 1)
        .offset(y: displacement)
        .animation(.easeOut(duration: DragVisuals.reshuffleDuration), value: displacement)
        .animation(.easeOut(duration: 0.12), value: isGhosted)
    }

    /// The selected row keeps the accent: its tabs already show their own
    /// status dots. Any other row carries its workspace's aggregate status,
    /// the one signal for an agent that needs attention elsewhere.
    private var indicatorColor: Color? {
        isSelected ? theme.accent : theme.agentStatusColor(workspace.agentStatus)
    }
}
