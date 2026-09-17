import AppKit
import PaddockCore
import SwiftUI

/// The tab strip: square tabs for the selected workspace plus the protocol
/// readout, over a rule. Read-only mirror, selection/jump, and the tab end of
/// the drag layer.
struct TabStrip: View {
    let theme: Theme
    let viewModel: SessionViewModel
    let workspace: WorkspaceID?
    let tabs: [TabRecord]
    let selectedTabID: TabID?
    let protocolVersion: Int
    let onSelect: (TabID) -> Void

    @Environment(DragCoordinator.self) private var drag
    @State private var scrollPosition = ScrollPosition()
    @State private var hoveredTabID: TabID?

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
                                isRenaming: viewModel.renameTarget == .tab(tab.tabID),
                                showsClose: hoveredTabID == tab.tabID && viewModel.renameTarget != .tab(tab.tabID),
                                renameText: viewModel.renameText(for: .tab(tab.tabID)),
                                onCommitRename: { text in Task { await viewModel.commitRename(text, for: .tab(tab.tabID)) } },
                                onCancelRename: { viewModel.cancelRename() },
                                onClose: { Task { await viewModel.closeTab(tab.tabID) } },
                                displacement: drag.tabDisplacement(at: index),
                                isGhosted: drag.isDragging(tab: tab.tabID)
                            )
                            // Outside the tab, which offsets its own content: an
                            // offset leaves the layout frame alone, so what is
                            // published here is the tab's resting place rather
                            // than its reshuffled one -- which is what the
                            // insertion index must be measured against.
                            .reportsFrame(in: DragSpace.stripContent) { drag.setTabFrame($0, for: tab.tabID) }
                            // A container, so the controls inside the tab keep
                            // their own identifiers: folded into its label,
                            // the tab's close button and rename editor are not
                            // reachable at all.
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("paddock.strip.tab.\(tab.tabID.rawValue)")
                            .onHover { hoveredTabID = $0 ? tab.tabID : (hoveredTabID == tab.tabID ? nil : hoveredTabID) }
                            // Both guarded: SwiftUI's tap gesture on macOS
                            // fires for the secondary button too, so without
                            // this a right-click selects the tab and two of
                            // them open the rename editor, on top of the
                            // context menu they were asking for.
                            .onTapGesture(count: 2) {
                                guard !NSEvent.isSecondaryButtonEvent(NSApp.currentEvent) else { return }
                                viewModel.beginRename(.tab(tab.tabID))
                            }
                            .onTapGesture {
                                guard !NSEvent.isSecondaryButtonEvent(NSApp.currentEvent) else { return }
                                onSelect(tab.tabID)
                            }
                            // Disarmed while this tab is being renamed: a press
                            // inside the field must reach the text, not start a
                            // drag.
                            .simultaneousGesture(tabDrag(tab), including: viewModel.renameTarget == .tab(tab.tabID) ? .subviews : .all)
                            .contextMenu {
                                ForEach(tabMenuEntries(for: tab.tabID), id: \.accessibilityIdentifier) { entry in
                                    Button(entry.label) {
                                        Task { await entry.action.perform(tabID: tab.tabID, on: viewModel) }
                                    }
                                    .accessibilityIdentifier(entry.accessibilityIdentifier)
                                }
                            }
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
                // Behind the tabs, so only the strip space no tab occupies
                // ever reaches it. herdr puts a "+" of its own at the end of
                // the strip; paddock's equivalent is this zone plus the tab
                // menu's New Tab and File > New Tab, so the resting chrome
                // carries no control the design never drew.
                .background { newTabZone }
                .overlay(alignment: .leading) {
                    if drag.stripEdgeFade.leading { edgeFade(leading: true) }
                }
                .overlay(alignment: .trailing) {
                    if drag.stripEdgeFade.trailing { edgeFade(leading: false) }
                }
                .onAppear {
                    drag.stripScroller = { x in scrollPosition.scrollTo(x: x) }
                    drag.stripRevealScroller = { x in
                        withAnimation(.easeOut(duration: DragVisuals.tabRevealDuration)) {
                            scrollPosition.scrollTo(x: x)
                        }
                    }
                }
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
        .onChange(of: selectedTabID) { _, id in if let id { drag.revealTab(id) } }
    }

    /// A plain click on strip space no tab occupies creates one. Invisible by
    /// construction, so it costs the resting chrome nothing.
    @ViewBuilder
    private var newTabZone: some View {
        if let workspace {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    guard !NSEvent.isSecondaryButtonEvent(NSApp.currentEvent) else { return }
                    Task { await viewModel.createTab(in: workspace) }
                }
                .accessibilityIdentifier("paddock.strip.newTab")
        }
    }

    private func tabMenuEntries(for tab: TabID) -> [ChromeMenuEntry<TabMenuAction>] {
        guard let model = viewModel.model else { return [] }
        return TabMenuModel.entries(for: tab, model: model)
    }

    /// Hints at tabs scrolled past this edge: the strip's own color run down
    /// to nothing, never intercepting the tabs or the drag frames under it.
    private func edgeFade(leading: Bool) -> some View {
        LinearGradient(
            colors: leading ? [theme.chrome, theme.chrome.opacity(0)] : [theme.chrome.opacity(0), theme.chrome],
            startPoint: .leading, endPoint: .trailing
        )
        .frame(width: ChromeMetrics.Strip.edgeFadeWidth)
        .allowsHitTesting(false)
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
    var isRenaming = false
    /// The hover-reveal close: laid out on every tab either way, so a tab
    /// never reflows as the pointer crosses it.
    var showsClose = false
    var renameText = ""
    var onCommitRename: (String) -> Void = { _ in }
    var onCancelRename: () -> Void = {}
    var onClose: () -> Void = {}
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
                if isRenaming {
                    InlineRenameField(
                        theme: theme, font: ChromeType.tabLabel(selected: isSelected), initialText: renameText,
                        accessibilityIdentifier: "paddock.strip.rename.\(tab.tabID.rawValue)",
                        onCommit: onCommitRename, onCancel: onCancelRename
                    )
                } else {
                    Text(tab.label)
                        .font(ChromeType.tabLabel(selected: isSelected))
                        .foregroundStyle(isSelected ? theme.textStrong : theme.textDim)
                        .lineLimit(1)
                    StatusDot(status: tab.agentStatus, theme: theme, size: ChromeMetrics.Tab.statusDot)
                }
            }
            .padding(.horizontal, ChromeMetrics.Tab.horizontalPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .overlay(alignment: .trailing) {
                HoverCloseButton(
                    theme: theme, isRevealed: showsClose, help: "Close tab",
                    accessibilityIdentifier: "paddock.strip.close.\(tab.tabID.rawValue)", action: onClose
                )
                .padding(.trailing, ChromeMetrics.Tab.horizontalPadding / 2)
            }
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
