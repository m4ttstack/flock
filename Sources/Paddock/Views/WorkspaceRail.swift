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
            VStack(alignment: .leading, spacing: 1) {
                Text("WORKSPACES")
                    .font(.system(size: 8, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(theme.textLabel)
                Spacer()
                    .frame(height: 6)

                ForEach(Array(workspaces.enumerated()), id: \.element.workspaceID) { index, workspace in
                    WorkspaceRow(
                        theme: theme,
                        workspace: workspace,
                        paneCount: viewModel.paneCount(for: workspace.workspaceID),
                        isSelected: workspace.workspaceID == viewModel.selectedWorkspaceID,
                        displacement: drag.workspaceDisplacement(at: index),
                        isGhosted: drag.isDragging(workspace: workspace.workspaceID)
                    )
                    // Outside the row, which offsets its own content: the frame
                    // published here is the row's resting place, which is what the
                    // insertion index is measured against.
                    .reportsDragFrame { drag.setWorkspaceFrame($0, for: workspace.workspaceID) }
                    .accessibilityIdentifier("paddock.rail.workspace.\(workspace.workspaceID.rawValue)")
                    .onTapGesture { onSelect(workspace.workspaceID) }
                    .simultaneousGesture(rowDrag(workspace))
                }

                Spacer(minLength: 0)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 8)
            .frame(width: ChromeMetrics.railWidth)
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
                drag.beginIfIdle(
                    .workspace(workspace.workspaceID),
                    ghost: DragCoordinator.Ghost(
                        title: workspace.label,
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
    /// How far this row slides to open the insertion gap.
    var displacement: CGFloat = 0
    /// The row this drag started from, left in place and faded.
    var isGhosted = false

    var body: some View {
        HStack(spacing: 6) {
            // Present on every row so names stay aligned, clear when there is
            // nothing to mark.
            RoundedRectangle(cornerRadius: 1)
                .fill(indicatorColor ?? .clear)
                .frame(width: 2, height: 12)
            Text(workspace.label)
                .font(.system(size: 11, weight: isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? theme.textStrong : theme.textDim)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text("\(paneCount)")
                .font(.system(size: 9))
                .foregroundStyle(theme.textLabel)
        }
        // The system font's 11pt line is taller than the row's 13pt content
        // band; fixed so rows keep their 21pt pitch.
        .frame(height: 13)
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 2)
                .fill(theme.selection)
                .opacity(isSelected ? 1 : 0)
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
