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
                            WorkspaceRow(
                                theme: theme,
                                workspace: workspace,
                                paneCount: viewModel.paneCount(for: workspace.workspaceID),
                                isSelected: workspace.workspaceID == viewModel.selectedWorkspaceID,
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
                            .onTapGesture {
                                let commandHeld = NSEvent.modifierFlags.contains(.command)
                                if drag.clickWorkspace(workspace.workspaceID, commandHeld: commandHeld, current: viewModel.selectedWorkspaceID) {
                                    onSelect(workspace.workspaceID)
                                }
                            }
                            .simultaneousGesture(rowDrag(workspace))
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

/// A square block behind the glyph that appears on hover and deepens while the
/// press is held.
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
                    .fill(configuration.isPressed ? theme.selection : theme.tabRest)
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
            Text(workspace.label)
                .font(ChromeType.workspaceName(selected: isSelected))
                .foregroundStyle(isSelected ? theme.textStrong : theme.textDim)
                .lineLimit(1)
            Spacer(minLength: ChromeMetrics.WorkspaceRow.countMinimumGap)
            Text("\(paneCount)")
                .font(ChromeType.workspaceCount)
                .foregroundStyle(theme.textLabel)
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
