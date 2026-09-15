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

    private var workspaces: [WorkspaceRecord] { viewModel.model?.workspaces ?? [] }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: ChromeMetrics.Rail.rowGap) {
                Text("WORKSPACES")
                    .font(ChromeType.railHeading)
                    .tracking(ChromeType.railHeadingTracking)
                    .foregroundStyle(theme.textLabel)
                Spacer()
                    .frame(height: ChromeMetrics.Rail.headingGap)

                ForEach(Array(workspaces.enumerated()), id: \.element.workspaceID) { index, workspace in
                    WorkspaceRow(
                        theme: theme,
                        workspace: workspace,
                        paneCount: viewModel.paneCount(for: workspace.workspaceID),
                        isSelected: workspace.workspaceID == viewModel.selectedWorkspaceID,
                        isMultiSelected: drag.isWorkspaceMultiSelected(workspace.workspaceID),
                        displacement: drag.workspaceDisplacement(at: index),
                        isGhosted: drag.isDragging(workspace: workspace.workspaceID)
                    )
                    // Outside the row, which offsets its own content: the frame
                    // published here is the row's resting place, which is what the
                    // insertion index is measured against.
                    .reportsDragFrame { drag.setWorkspaceFrame($0, for: workspace.workspaceID) }
                    .accessibilityIdentifier("paddock.rail.workspace.\(workspace.workspaceID.rawValue)")
                    .onTapGesture {
                        let commandHeld = NSEvent.modifierFlags.contains(.command)
                        if drag.clickWorkspace(workspace.workspaceID, commandHeld: commandHeld) {
                            onSelect(workspace.workspaceID)
                        }
                    }
                    .simultaneousGesture(rowDrag(workspace))
                }

                Spacer(minLength: 0)
            }
            .padding(.vertical, ChromeMetrics.Rail.verticalPadding)
            .padding(.horizontal, ChromeMetrics.Rail.horizontalPadding)
            .frame(width: ChromeMetrics.Rail.width)
            .frame(maxHeight: .infinity, alignment: .top)
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

private struct WorkspaceRow: View {
    let theme: Theme
    let workspace: WorkspaceRecord
    let paneCount: Int
    let isSelected: Bool
    /// In the rail's Cmd+click selection: the fill only, since the accent bar
    /// and weight mark herdr's own selected workspace.
    var isMultiSelected = false
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
                .opacity(isSelected || isMultiSelected ? 1 : 0)
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
