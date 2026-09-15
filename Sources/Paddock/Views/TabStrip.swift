import PaddockCore
import SwiftUI

/// The tab strip: square tabs for the selected workspace plus the protocol
/// readout, over a rule. Read-only mirror, selection/jump, and the tab end of
/// the drag layer.
struct TabStrip: View {
    let theme: Theme
    let workspace: WorkspaceID?
    let tabs: [TabRecord]
    let selectedTabID: TabID?
    let protocolVersion: Int
    let onSelect: (TabID) -> Void

    @Environment(DragCoordinator.self) private var drag
    @State private var scrollPosition = ScrollPosition()

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: ChromeMetrics.Strip.tabGap) {
                // Tabs scroll once they overflow; the readout never does. The
                // leading padding is scroll content, so overflowing tabs scroll
                // to the rail's rule while a strip that fits keeps its inset.
                ScrollView(.horizontal) {
                    HStack(alignment: .bottom, spacing: ChromeMetrics.Strip.tabGap) {
                        ForEach(Array(tabs.enumerated()), id: \.element.tabID) { index, tab in
                            TabBlock(
                                theme: theme,
                                tab: tab,
                                isSelected: tab.tabID == selectedTabID,
                                displacement: drag.tabDisplacement(at: index),
                                isGhosted: drag.isDragging(tab: tab.tabID)
                            )
                            // Outside the tab, which offsets its own content: an
                            // offset leaves the layout frame alone, so what is
                            // published here is the tab's resting place rather
                            // than its reshuffled one -- which is what the
                            // insertion index must be measured against.
                            .reportsFrame(in: DragSpace.stripContent) { drag.setTabFrame($0, for: tab.tabID) }
                            .accessibilityIdentifier("paddock.strip.tab.\(tab.tabID.rawValue)")
                            .onTapGesture { onSelect(tab.tabID) }
                            .simultaneousGesture(tabDrag(tab))
                        }
                    }
                    .padding(.leading, ChromeMetrics.Strip.horizontalPadding)
                    .frame(height: ChromeMetrics.Strip.height, alignment: .bottom)
                    .coordinateSpace(.named(DragSpace.stripContent))
                    .reportsDragFrame { drag.setStripContentOrigin($0.origin) }
                }
                .scrollIndicators(.never)
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                .scrollPosition($scrollPosition)
                .reportsScrollExtent(.horizontal) { drag.setStripScroll(offset: $0, maximumOffset: $1) }
                .frame(height: ChromeMetrics.Strip.height)
                .reportsDragFrame { drag.stripViewport = $0 }
                .onAppear { drag.stripScroller = { x in scrollPosition.scrollTo(x: x) } }
                Text("protocol \(protocolVersion)")
                    .font(ChromeType.protocolReadout)
                    .foregroundStyle(theme.textLabel)
                    .padding(.bottom, ChromeMetrics.Strip.readoutBottomInset)
                    .frame(height: ChromeMetrics.Strip.height)
                    .reportsDragFrame { drag.stripTrailingLimit = $0.minX }
            }
            .padding(.trailing, ChromeMetrics.Strip.horizontalPadding)
            .frame(height: ChromeMetrics.Strip.height)
            // The strip above its rule: the insertion bar is clamped inside
            // this frame, so a frame that included the rule would let the bar
            // cross it into the canvas.
            .reportsDragFrame { drag.stripFrame = $0 }
            Rectangle()
                .fill(theme.rule)
                .frame(height: ChromeMetrics.ruleWidth)
        }
        .background(WindowDragExclusion())
        .boundedBackground(theme.chrome)
        .onAppear { publishIdentity() }
        .onChange(of: tabs.map(\.tabID)) { _, _ in publishIdentity() }
        .onChange(of: workspace) { _, _ in publishIdentity() }
    }

    /// The strip's own order and workspace: `DropTarget`'s tab cases carry a
    /// workspace id the tab frames themselves cannot supply, and the order is
    /// what turns those frames back into a list.
    private func publishIdentity() {
        drag.stripWorkspace = workspace
        drag.setTabOrder(tabs.map(\.tabID))
    }

    /// Starts the drag and nothing else: `DragCoordinator` drives it from
    /// there, off window-level monitors, so no per-tab latch can be left
    /// behind by a strip that is rebuilt mid-drag.
    private func tabDrag(_ tab: TabRecord) -> some Gesture {
        DragGesture(minimumDistance: DragThreshold.movement, coordinateSpace: .named(DragSpace.name))
            .onChanged { value in
                drag.beginIfIdle(
                    .tab(tab.tabID),
                    ghost: DragCoordinator.Ghost(
                        title: tab.label,
                        symbol: "rectangle.stack",
                        originSize: drag.tabFrames.first { $0.id == tab.tabID }?.frame.size ?? .zero
                    ),
                    at: value.startLocation
                )
            }
    }
}

private struct TabBlock: View {
    let theme: Theme
    let tab: TabRecord
    let isSelected: Bool
    /// How far this tab slides to open the insertion gap.
    var displacement: CGFloat = 0
    /// The tab this drag started from, left in place and faded.
    var isGhosted = false

    var body: some View {
        // The underline takes its height out of the selected block, so the
        // selected label centers on the block above it; resting tabs have no
        // underline slot at all.
        VStack(spacing: 0) {
            HStack(spacing: ChromeMetrics.Tab.labelDotGap) {
                Text(tab.label)
                    .font(ChromeType.tabLabel(selected: isSelected))
                    .foregroundStyle(isSelected ? theme.textStrong : theme.textDim)
                    .lineLimit(1)
                StatusDot(status: tab.agentStatus, theme: theme, size: ChromeMetrics.Tab.statusDot)
            }
            .padding(.horizontal, ChromeMetrics.Tab.horizontalPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .boundedBackground(isSelected ? theme.selection : theme.tabRest)
            if isSelected {
                Rectangle()
                    .fill(theme.accent)
                    .frame(height: ChromeMetrics.Tab.underlineHeight)
            }
        }
        .frame(width: ChromeMetrics.Tab.size.width, height: ChromeMetrics.Tab.size.height)
        .contentShape(Rectangle())
        .opacity(isGhosted ? DragVisuals.originOpacity : 1)
        .offset(x: displacement)
        .animation(.easeOut(duration: DragVisuals.reshuffleDuration), value: displacement)
        .animation(.easeOut(duration: 0.12), value: isGhosted)
    }
}
