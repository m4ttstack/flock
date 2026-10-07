import AppKit
import FlockCore
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
    /// The connected herdr's release; nil until a snapshot has landed.
    let herdrVersion: String?
    let onSelect: (TabID) -> Void
    /// Exists only so a render test can sample the new-tab affordance's drawn
    /// state without simulating a real pointer -- production call sites never
    /// pass it, and hovering still drives the affordance's own state from
    /// there on.
    var previewHoversNewTabAffordance = false

    @Environment(DragCoordinator.self) private var drag
    @State private var scrollPosition = ScrollPosition()
    @State private var hoveredTabID: TabID?
    @State private var completeGroupWidth: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: ChromeMetrics.Strip.tabGap) {
                // Tabs scroll once they overflow; the readout never does. The
                // leading padding is scroll content, so overflowing tabs scroll
                // to the rail's rule while a strip that fits keeps its inset.
                ScrollView(.horizontal) {
                    HStack(alignment: .bottom, spacing: ChromeMetrics.Strip.tabGap) {
                        ForEach(Array(openTabs.enumerated()), id: \.element.tabID) { index, tab in
                            tabCell(tab, index: index)
                        }
                        // A real sibling in the same content, so it scrolls
                        // and hit-tests with the tabs rather than behind them
                        // (`newTabZone` below sits behind the scroll view for
                        // exactly the reason the rail's own zone once broke
                        // there: an `NSScrollView` claims hit testing across
                        // its own bounds). `nil` when the strip has no
                        // unscrolled room left, which leaves nothing drawn at
                        // all rather than an affordance no hover could ever
                        // reach without scrolling first.
                        if let workspace, newTabAffordanceFrame != nil {
                            NewTabAffordanceButton(
                                theme: theme, onCreate: { Task { await viewModel.createTab(in: workspace) } },
                                previewHovering: previewHoversNewTabAffordance
                            )
                        }
                        if !completeTabs.isEmpty {
                            Spacer(minLength: 0)
                            completeGroup
                                .reportsDragFrame { completeGroupWidth = $0.width }
                        }
                    }
                    .padding(.leading, ChromeMetrics.Strip.horizontalPadding)
                    .padding(.trailing, completeTabs.isEmpty ? 0 : ChromeMetrics.Strip.horizontalPadding)
                    // As wide as the viewport at least, so the complete group
                    // sits at the strip's far end while the tabs still fit.
                    .frame(minWidth: drag.stripViewport?.width ?? 0, alignment: .leading)
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
                // the strip; flock's equivalent is this zone plus the tab
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
                Text(herdrVersion.map { "herdr v\($0)" } ?? "")
                    .font(ChromeType.versionReadout)
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
        .onChange(of: workspace.flatMap { viewModel.model?.tabs[$0] }?.map(\.tabID)) { _, _ in publishIdentity() }
        .onChange(of: workspace) { _, _ in publishIdentity() }
        .onChange(of: completeTabs.map(\.tabID)) { _, _ in publishIdentity() }
        .onChange(of: selectedTabID) { _, id in if let id { drag.revealTab(id) } }
    }

    private var openTabs: [TabRecord] { tabs.filter { !viewModel.completedTabs.isComplete($0.tabID) } }
    private var completeTabs: [TabRecord] { tabs.filter { viewModel.completedTabs.isComplete($0.tabID) } }

    /// The complete tabs as a stack of cards, each tucked under the next. The
    /// hovered or selected one comes to the front.
    private var completeGroup: some View {
        HStack(alignment: .bottom, spacing: -ChromeMetrics.Tab.completeOverlap) {
            ForEach(Array(completeTabs.enumerated()), id: \.element.tabID) { offset, tab in
                tabCell(tab, index: openTabs.count + offset)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(theme.rule).frame(width: ChromeMetrics.ruleWidth)
                    }
                    .zIndex(tab.tabID == hoveredTabID ? Double(tabs.count + 1) : tab.tabID == selectedTabID ? Double(tabs.count) : Double(offset))
            }
        }
    }

    @ViewBuilder
    private func tabCell(_ tab: TabRecord, index: Int) -> some View {
        TabBlock(
            theme: theme,
            tab: tab,
            title: title(for: tab),
            isSelected: tab.tabID == selectedTabID,
            isComplete: viewModel.completedTabs.isComplete(tab.tabID),
            isLifted: hoveredTabID == tab.tabID && viewModel.completedTabs.isComplete(tab.tabID),
            isRenaming: viewModel.renameTarget == .tab(tab.tabID),
            showsClose: hoveredTabID == tab.tabID && viewModel.renameTarget != .tab(tab.tabID),
            renameText: viewModel.renameText(for: .tab(tab.tabID)),
            onCommitRename: { text in Task { await viewModel.commitRename(text, for: .tab(tab.tabID)) } },
            onCancelRename: { viewModel.cancelRename() },
            onClose: { Task { await viewModel.closeTab(tab.tabID) } },
            displacement: drag.tabDisplacement(at: index),
            isGhosted: drag.isDragging(tab: tab.tabID),
            isBackground: viewModel.shownStatus(of: tab).isBackground
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
        .accessibilityIdentifier("flock.strip.tab.\(tab.tabID.rawValue)")
        .onHover { hoveredTabID = $0 ? tab.tabID : (hoveredTabID == tab.tabID ? nil : hoveredTabID) }
        .onTapGesture { handleClick(on: tab.tabID, select: onSelect) }
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

    /// `tabsEnd` -- every current tab's own width, gaps and the strip's own
    /// leading inset summed -- is what `TabSizing` already knows for each tab
    /// on screen; the pure decision of where that leaves room, and whether
    /// there is any, is `NewTabAffordance`'s.
    private var newTabAffordanceFrame: CGRect? {
        let gap = ChromeMetrics.Strip.tabGap
        let open = openTabs
        let tabsWidth = open.reduce(CGFloat(0)) { $0 + TabSizing.width(of: title(for: $1)) }
        let tabsEnd = ChromeMetrics.Strip.horizontalPadding + tabsWidth + gap * CGFloat(max(open.count - 1, 0))
        let completeRoom = completeTabs.isEmpty ? 0 : completeGroupWidth + gap
        return NewTabAffordance.frame(
            tabsEnd: tabsEnd, gap: gap, viewportWidth: max((drag.stripViewport?.width ?? 0) - completeRoom, 0),
            height: ChromeMetrics.Tab.height
        )
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
                .accessibilityIdentifier("flock.strip.newTab")
        }
    }

    /// A double click selects on its way into the editor, which is the price
    /// of never holding a plain click back to find out whether a second one is
    /// coming.
    private func handleClick(on tab: TabID, select: (TabID) -> Void) {
        switch NSEvent.chromeRowClick(NSApp.currentEvent) {
        case .select: select(tab)
        case .beginRename: viewModel.beginRename(.tab(tab))
        case .ignore: break
        }
    }

    private func tabMenuEntries(for tab: TabID) -> [ChromeMenuEntry<TabMenuAction>] {
        guard let model = viewModel.model else { return [] }
        return TabMenuModel.entries(for: tab, model: model, isComplete: viewModel.completedTabs.isComplete(tab))
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

    private func title(for tab: TabRecord) -> TabTitle {
        viewModel.model.map { TabTitle.resolve(tab, in: $0) } ?? TabTitle(text: tab.label, isFromPane: false)
    }

    /// The strip's own order and workspace: `DropTarget`'s tab cases carry a
    /// workspace id the tab frames themselves cannot supply, and the order is
    /// what turns those frames back into a list.
    private func publishIdentity() {
        drag.stripWorkspace = workspace
        drag.stripCompleteTabs = Set(completeTabs.map(\.tabID))
        drag.setTabOrder(tabs.map(\.tabID), modelOrder: workspace.flatMap { viewModel.model?.tabs[$0] }?.map(\.tabID) ?? [])
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
                        title: title(for: tab).text,
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
    let title: TabTitle
    let isSelected: Bool
    var isComplete = false
    /// A complete tab under the pointer, drawn out of its stack.
    var isLifted = false
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
    var isBackground = false

    /// One place, two controls. The close stands where the dot stands rather
    /// than over it, and the slot keeps the width of the wider of them, so a
    /// tab neither reflows as the pointer crosses it nor lets the close reach
    /// back over the title.
    private var trailingSlot: some View {
        ZStack {
            StatusDot(status: tab.agentStatus, theme: theme, size: ChromeMetrics.Tab.statusDot, isBackground: isBackground)
                .opacity(showsClose ? 0 : 1)
            HoverCloseButton(
                theme: theme, isRevealed: showsClose, help: "Close tab",
                accessibilityIdentifier: "flock.strip.close.\(tab.tabID.rawValue)", action: onClose
            )
        }
        .frame(width: ChromeMetrics.Tab.trailingSlot)
    }

    private var labelColor: Color { isSelected || isLifted ? theme.textStrong : theme.textDim }

    private var titleOpacity: Double { isComplete && !isLifted ? ChromeMetrics.Tab.completeTitleOpacity : 1 }

    var body: some View {
        // The underline takes its height out of the selected block, so the
        // selected label centers on the block above it; resting tabs have no
        // underline slot at all.
        VStack(spacing: 0) {
            // No stack spacing here: the gap comes from the spacer's own
            // minLength, so a tab with slack cannot double it up between the
            // label and a spacer both.
            HStack(spacing: 0) {
                if isRenaming {
                    InlineRenameField(
                        theme: theme, font: ChromeType.tabLabel(selected: isSelected), initialText: renameText,
                        accessibilityIdentifier: "flock.strip.rename.\(tab.tabID.rawValue)",
                        onCommit: onCommitRename, onCancel: onCancelRename
                    )
                } else {
                    if isComplete {
                        Image(systemName: ChromeType.tabCompleteGlyphName)
                            .font(ChromeType.tabCompleteGlyph)
                            .foregroundStyle(theme.mauve)
                            .frame(width: ChromeMetrics.Tab.completeGlyphWidth)
                            .padding(.trailing, ChromeMetrics.Tab.completeGlyphGap)
                            .accessibilityLabel("Complete")
                    }
                    if title.isFromPane {
                        Image(systemName: ChromeType.tabPaneGlyphName)
                            .font(ChromeType.tabPaneGlyph)
                            .foregroundStyle(theme.textLabel)
                            .opacity(titleOpacity)
                            .frame(width: ChromeMetrics.Tab.paneGlyphWidth)
                            .padding(.trailing, ChromeMetrics.Tab.paneGlyphGap)
                            .accessibilityLabel("Named after its pane")
                    }
                    Text(title.text)
                        .font(ChromeType.tabLabel(selected: isSelected))
                        .foregroundStyle(labelColor)
                        .opacity(titleOpacity)
                        .lineLimit(1)
                    Spacer(minLength: ChromeMetrics.Tab.labelDotGap)
                    trailingSlot
                }
            }
            .padding(.horizontal, ChromeMetrics.Tab.horizontalPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .boundedBackground(isSelected || isLifted ? theme.selection : theme.tabRest)
            if isSelected {
                Rectangle()
                    .fill(theme.accent)
                    .frame(height: ChromeMetrics.Tab.underlineHeight)
            }
        }
        // Sized off the tab's own label, not the editor's text: a rename in
        // flight must not resize the tab under the field, nor slide the tabs
        // after it along the strip with every keystroke.
        .frame(width: TabSizing.width(of: title, isComplete: isComplete, isSelected: isSelected), height: ChromeMetrics.Tab.height)
        // Rounded on top only: the bottom edge meets the pane below.
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: ChromeRadius.control, topTrailingRadius: ChromeRadius.control))
        .shadow(color: .black.opacity(isLifted ? 0.35 : 0), radius: 4)
        .animation(.easeOut(duration: 0.12), value: isLifted)
        .contentShape(Rectangle())
        .opacity(isGhosted ? DragVisuals.originOpacity : 1)
        .offset(x: displacement)
        .animation(.easeOut(duration: DragVisuals.reshuffleDuration), value: displacement)
        .animation(.easeOut(duration: 0.12), value: isGhosted)
    }
}

/// The strip's own free run past the last tab, previewing the tab a click
/// there creates: an outline rather than a filled block, which is what keeps
/// it reading as a preview beside the real tabs it borrows its shape from.
/// Invisible at rest -- `isHovering` alone decides whether anything is drawn,
/// so a hover that ends mid-press leaves nothing behind.
private struct NewTabAffordanceButton: View {
    let theme: Theme
    let onCreate: () -> Void

    init(theme: Theme, onCreate: @escaping () -> Void, previewHovering: Bool = false) {
        self.theme = theme
        self.onCreate = onCreate
        self._isHovering = State(initialValue: previewHovering)
    }

    @State private var isHovering: Bool

    var body: some View {
        UnevenRoundedRectangle(topLeadingRadius: ChromeRadius.control, topTrailingRadius: ChromeRadius.control)
            .strokeBorder(theme.rule, lineWidth: ChromeMetrics.ruleWidth)
            .overlay(
                Image(systemName: ChromeType.newTabSymbolName)
                    .font(ChromeType.newTabSymbol)
                    .foregroundStyle(theme.textLabel)
            )
            .frame(width: NewTabAffordance.width, height: ChromeMetrics.Tab.height)
            .opacity(isHovering ? 1 : 0)
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .onTapGesture(perform: onCreate)
            .accessibilityIdentifier("flock.strip.newTab.affordance")
            .accessibilityLabel("New Tab")
    }
}
