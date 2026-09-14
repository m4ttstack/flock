import PaddockCore
import SwiftUI

/// The 216px workspace source list. Read-only mirror, selection/jump, and the
/// workspace end of the drag layer; stays untested until the e2e suite per the
/// task brief.
struct WorkspaceRail: View {
    let theme: Theme
    let viewModel: SessionViewModel
    let onSelect: (WorkspaceID) -> Void

    @Environment(DragCoordinator.self) private var drag

    private var workspaces: [WorkspaceRecord] { viewModel.model?.workspaces ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("WORKSPACES")
                .font(.system(size: 10, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(theme.overlay0)
                .padding(.horizontal, 10)
                .padding(.top, 4)
                .padding(.bottom, 8)

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
        .padding(8)
        .frame(width: 216)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(theme.railBg)
        .overlay(alignment: .trailing) {
            Rectangle().fill(theme.separator).frame(width: 1)
        }
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
        HStack(spacing: 9) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 11))
                .foregroundStyle(isSelected ? theme.accent : theme.overlay0)
                .frame(width: 18)
            Text(workspace.label)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? theme.text : theme.subtext0)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text("\(paneCount)")
                .font(.system(size: 10))
                .foregroundStyle(theme.overlay0)
            StatusDot(status: workspace.agentStatus, theme: theme)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? theme.accent.opacity(0.16) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? theme.accent.opacity(0.35) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .opacity(isGhosted ? DragVisuals.originOpacity : 1)
        .offset(y: displacement)
        .animation(.easeOut(duration: DragVisuals.reshuffleDuration), value: displacement)
        .animation(.easeOut(duration: 0.12), value: isGhosted)
    }
}
