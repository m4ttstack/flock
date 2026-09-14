import PaddockCore
import SwiftUI

/// The 42px tab strip: pill tabs for the selected workspace plus the
/// "protocol NN" readout. Read-only mirror, selection/jump, and the tab end of
/// the drag layer; stays untested until the e2e suite per the task brief.
struct TabStrip: View {
    let theme: Theme
    let workspace: WorkspaceID?
    let tabs: [TabRecord]
    let selectedTabID: TabID?
    let protocolVersion: Int
    let onSelect: (TabID) -> Void

    @Environment(DragCoordinator.self) private var drag
    @State private var draggingTab: TabID?

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(tabs.enumerated()), id: \.element.tabID) { index, tab in
                TabPill(
                    theme: theme,
                    tab: tab,
                    isSelected: tab.tabID == selectedTabID,
                    displacement: drag.tabDisplacement(at: index),
                    isGhosted: drag.isDragging(tab: tab.tabID)
                )
                // Outside the pill, which offsets its own content: an offset
                // leaves the layout frame alone, so what is published here is
                // the pill's resting place rather than its reshuffled one --
                // which is what the insertion index must be measured against.
                .reportsDragFrame { drag.setTabFrame($0, for: tab.tabID) }
                .accessibilityIdentifier("paddock.strip.tab.\(tab.tabID.rawValue)")
                .onTapGesture { onSelect(tab.tabID) }
                .simultaneousGesture(pillDrag(tab))
            }
            Spacer(minLength: 0)
            Text("protocol \(protocolVersion)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(theme.overlay0)
                .reportsDragFrame { drag.stripTrailingLimit = $0.minX }
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .background(theme.tabStripBg)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.separator).frame(height: 1)
        }
        .reportsDragFrame { drag.stripFrame = $0 }
        .onAppear { publishIdentity() }
        .onChange(of: tabs.map(\.tabID)) { _, _ in publishIdentity() }
        .onChange(of: workspace) { _, _ in publishIdentity() }
    }

    /// The strip's own order and workspace: `DropTarget`'s tab cases carry a
    /// workspace id the pill frames themselves cannot supply, and the order is
    /// what turns those frames back into a list.
    private func publishIdentity() {
        drag.stripWorkspace = workspace
        drag.setTabOrder(tabs.map(\.tabID))
    }

    private func pillDrag(_ tab: TabRecord) -> some Gesture {
        DragGesture(minimumDistance: DragThreshold.movement, coordinateSpace: .named(DragSpace.name))
            .onChanged { value in
                if draggingTab != tab.tabID {
                    draggingTab = tab.tabID
                    drag.begin(
                        .tab(tab.tabID),
                        ghost: DragCoordinator.Ghost(
                            title: tab.label,
                            symbol: "rectangle.stack",
                            originSize: drag.tabFrames.first { $0.id == tab.tabID }?.frame.size ?? .zero
                        ),
                        at: value.startLocation
                    )
                }
                drag.move(to: value.location)
            }
            .onEnded { _ in
                guard draggingTab == tab.tabID else { return }
                draggingTab = nil
                drag.end()
            }
    }
}

private struct TabPill: View {
    let theme: Theme
    let tab: TabRecord
    let isSelected: Bool
    /// How far this pill slides to open the insertion gap.
    var displacement: CGFloat = 0
    /// The pill this drag started from, left in place and faded.
    var isGhosted = false

    var body: some View {
        HStack(spacing: 7) {
            Text(tab.label)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? theme.chromeTextStrong : theme.chromeTextDim)
            StatusDot(status: tab.agentStatus, theme: theme, size: 7)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            // The selected pill's own surface role -- see `Theme`'s doc on
            // `tabPillSelectedBg`/`tabPillSelectedBorder` for why these are
            // distinct roles from `separator` rather than a reuse of it.
            RoundedRectangle(cornerRadius: 7)
                .fill(isSelected ? theme.tabPillSelectedBg : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(isSelected ? theme.tabPillSelectedBorder : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .opacity(isGhosted ? DragVisuals.originOpacity : 1)
        .offset(x: displacement)
        .animation(.easeOut(duration: DragVisuals.reshuffleDuration), value: displacement)
        .animation(.easeOut(duration: 0.12), value: isGhosted)
    }
}
