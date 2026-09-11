import PaddockCore
import SwiftUI

/// The 216px workspace source list. Read-only mirror + selection/jump only;
/// stays untested until the e2e suite per the task brief.
struct WorkspaceRail: View {
    let theme: Theme
    let model: SessionModel?
    let selectedWorkspaceID: WorkspaceID?
    let onSelect: (WorkspaceID) -> Void

    private var workspaces: [WorkspaceRecord] { model?.workspaces ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("WORKSPACES")
                .font(.system(size: 10, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(theme.overlay0)
                .padding(.horizontal, 10)
                .padding(.top, 4)
                .padding(.bottom, 8)

            ForEach(workspaces, id: \.workspaceID) { workspace in
                WorkspaceRow(
                    theme: theme,
                    workspace: workspace,
                    paneCount: paneCount(for: workspace.workspaceID),
                    isSelected: workspace.workspaceID == selectedWorkspaceID
                )
                .accessibilityIdentifier("paddock.rail.workspace.\(workspace.workspaceID.rawValue)")
                .onTapGesture { onSelect(workspace.workspaceID) }
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
    }

    private func paneCount(for workspaceID: WorkspaceID) -> Int {
        model?.panes.values.filter { $0.workspaceID == workspaceID }.count ?? 0
    }
}

private struct WorkspaceRow: View {
    let theme: Theme
    let workspace: WorkspaceRecord
    let paneCount: Int
    let isSelected: Bool

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
    }
}
