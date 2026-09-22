import AppKit
import FlockCore
import SwiftUI

/// The workspaces the board app launches its panes into, as ordinary
/// workspace rows grouped under a header that folds them. Folded, the header
/// carries the loudest of their dots, so a blocked pane is never hidden by
/// folding. `RailSections` decides which workspaces these are and that dot.
struct BoardSection: View {
    let theme: Theme
    let workspaces: [WorkspaceRecord]
    let logo: NSImage?
    let paneCount: (WorkspaceID) -> Int
    let selectedWorkspaceID: WorkspaceID?
    let showsFill: (WorkspaceID) -> Bool
    let onClick: (WorkspaceID) -> Void

    @Environment(SectionCollapseStore.self) private var collapse

    var body: some View {
        let isCollapsed = collapse.isCollapsed(.board)
        VStack(alignment: .leading, spacing: ChromeMetrics.Rail.rowGap) {
            RailSectionHeader(
                theme: theme, title: "BOARD", isCollapsed: isCollapsed,
                accessibilityIdentifier: "flock.rail.board.toggle", toggle: { collapse.toggle(.board) }
            ) {
                BoardLogo(image: logo)
            } trailing: {
                if let status = RailSections.boardHeaderStatus(for: workspaces, isCollapsed: isCollapsed) {
                    StatusDot(status: status, theme: theme, size: ChromeMetrics.WorkspaceRow.statusDot)
                }
            }
            if !isCollapsed {
                ForEach(workspaces, id: \.workspaceID) { workspace in
                    WorkspaceRow(
                        theme: theme,
                        workspace: workspace,
                        paneCount: paneCount(workspace.workspaceID),
                        isSelected: workspace.workspaceID == selectedWorkspaceID,
                        showsFill: showsFill(workspace.workspaceID)
                    )
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("flock.rail.board.workspace.\(workspace.workspaceID.rawValue)")
                    .onTapGesture { onClick(workspace.workspaceID) }
                }
            }
        }
        .padding(.top, ChromeMetrics.RailSection.sectionGap)
    }
}

/// The board app's own logo, or nothing at all while there is none: the box
/// is held either way, so BOARD sits where it always does.
private struct BoardLogo: View {
    let image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Color.clear
            }
        }
        .frame(width: ChromeMetrics.RailSection.headerMark, height: ChromeMetrics.RailSection.headerMark)
        .accessibilityHidden(true)
    }
}
