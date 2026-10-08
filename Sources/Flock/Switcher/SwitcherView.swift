import FlockCore
import SwiftUI

/// Both hold-and-tap switchers over the tab area: ⌃Tab's workspaces and ⌥Tab's
/// tabs in the selected workspace. Each blocks the other while it is up.
struct SwitcherOverlay: View {
    let theme: Theme
    let viewModel: SessionViewModel

    @Environment(WorkspaceSwitcher.self) private var workspaces
    @Environment(TabSwitcher.self) private var tabs
    @Environment(CommandPaletteState.self) private var commandPalette
    @Environment(ChatStore.self) private var chatStore

    var body: some View {
        let palette = commandPalette
        let busy = { [viewModel] in palette.isOpen || viewModel.renameEditorIsOnScreen || viewModel.rt.modal != nil }
        ZStack {
            SwitcherView(
                theme: theme, switcher: workspaces, trigger: .control, accessibilityPrefix: "flock.switcher",
                heading: "Workspaces",
                row: { [viewModel] id in Self.workspaceRow(id, viewModel: viewModel) },
                candidates: { [viewModel] in Self.workspaceCandidates(viewModel: viewModel) },
                current: { [viewModel] in viewModel.selectedWorkspaceID },
                blocked: { [tabs] in busy() || tabs.isActive },
                go: { [viewModel] id in
                    Task {
                        if let pin = PinID(switcherID: id) { viewModel.show(emptyPin: pin) } else { await viewModel.jumpToHerdr(workspace: id) }
                    }
                }
            )
            // Chat's names only where chat runs at all: without herdr-chat or
            // rt the box keeps its narrow width and no row asks after anyone.
            let chat = chatStore.isAvailable ? chatStore : nil
            SwitcherView(
                theme: theme, switcher: tabs, trigger: .option, accessibilityPrefix: "flock.tabSwitcher",
                heading: "Tabs",
                width: chat == nil ? ChromeMetrics.Switcher.width : ChromeMetrics.Switcher.chatWidth,
                scope: { [viewModel] in
                    viewModel.model?.workspaces.first { $0.workspaceID == viewModel.selectedWorkspaceID }?.label
                },
                row: { [viewModel] id in
                    guard let model = viewModel.model, let tab = viewModel.tabsForSelectedWorkspace.first(where: { $0.tabID == id })
                    else { return nil }
                    return SwitcherRow(
                        status: tab.agentStatus, label: TabSwitcher.title(for: tab, in: model), count: tab.paneCount,
                        chat: chat.flatMap { TabChatPresence.label(for: tab, in: model, buddies: $0.buddies) }
                    )
                },
                onBegin: { if let chat { Task { await chat.refreshBuddies() } } },
                candidates: { [viewModel] in viewModel.tabsForSelectedWorkspace.map(\.tabID) },
                current: { [viewModel] in viewModel.selectedTabID },
                blocked: { [workspaces] in busy() || workspaces.isActive },
                go: { [viewModel] id in Task { await viewModel.jumpToHerdr(tab: id) } }
            )
        }
    }

    static func workspaceRow(_ id: WorkspaceID, viewModel: SessionViewModel) -> SwitcherRow? {
        if let pin = PinID(switcherID: id).flatMap({ viewModel.pins.pin($0) }) {
            return .emptyPin(label: pin.name)
        }
        return viewModel.model?.workspaces.first { $0.workspaceID == id }.map {
            SwitcherRow(status: $0.agentStatus, label: $0.label, count: viewModel.paneCount(for: id))
        }
    }

    static func workspaceCandidates(viewModel: SessionViewModel) -> [WorkspaceID] {
        WorkspaceSwitcher.candidates(
            viewModel.model?.workspaces ?? [], current: viewModel.selectedWorkspaceID, pins: viewModel.pins.pins
        )
    }
}

struct SwitcherRow {
    let status: AgentStatus
    let label: String
    let count: Int
    /// Who in this tab is signed in to chat, when anyone is.
    var chat: String? = nil
    /// Drawn as the rail draws an empty pin: no dot, the name dimmed, no
    /// count.
    var isEmptyPin = false

    static func emptyPin(label: String) -> SwitcherRow {
        SwitcherRow(status: .unknown, label: label, count: 0, isEmptyPin: true)
    }
}

/// A drawn row and its index in the switcher's `order`.
struct SwitcherLine<ID: Hashable> {
    let index: Int
    let id: ID
    let row: SwitcherRow
}

/// One switcher's panel: the items most recently used first, the one letting
/// go of the trigger will open selected. Draws nothing until the switcher
/// shows, so a quick tap never flashes it; the key monitor that starts it
/// lives as long as the tab area does.
struct SwitcherView<ID: Hashable & Sendable & RawRepresentable<String>>: View {
    let theme: Theme
    let switcher: RecentsSwitcher<ID>
    let trigger: SwitcherTrigger
    let accessibilityPrefix: String
    /// The header's heading, in the rail's heading style, and what it is
    /// scoped to, if anything, on the right.
    let heading: String
    var width: CGFloat = ChromeMetrics.Switcher.width
    var scope: () -> String? = { nil }
    let row: (ID) -> SwitcherRow?
    /// Runs as the trigger first goes down, before the box shows.
    var onBegin: () -> Void = {}
    let candidates: () -> [ID]
    let current: () -> ID?
    let blocked: () -> Bool
    let go: (ID) -> Void

    @State private var monitor = SwitcherMonitor<ID>()

    private typealias Metrics = ChromeMetrics.Palette

    var body: some View {
        ZStack {
            if switcher.isShown {
                let rows = switcher.order.enumerated().compactMap { index, id in row(id).map { SwitcherLine(index: index, id: id, row: $0) } }
                GeometryReader { proxy in
                    ZStack(alignment: .top) {
                        scrim
                        box(rows: rows, maxListHeight: ChromeMetrics.Switcher.maxListHeight(inTabAreaHeight: proxy.size.height))
                            .padding(.top, ChromeMetrics.Switcher.top(inTabAreaHeight: proxy.size.height, rowCount: rows.count))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            monitor.install(
                switcher: switcher, trigger: trigger, blocked: blocked, begin: begin,
                open: { if let target = switcher.finish() { go(target) } }
            )
        }
        .onDisappear { monitor.remove() }
    }

    /// Only items that draw a row are offered, so `selection`, which counts
    /// `order`, counts the rows as drawn.
    func begin(reverse: Bool) {
        let items = candidates().filter { row($0) != nil }
        guard switcher.begin(items: items, current: current(), reverse: reverse) else { return }
        onBegin()
        let session = switcher.session
        Task {
            try? await Task.sleep(for: ChromeMetrics.Switcher.showDelay)
            switcher.show(session: session)
        }
    }

    private var scrim: some View {
        let isLight = ChromeRoles.isLight(panelBg: theme.palette.panelBg)
        return Color.black
            .opacity(isLight ? ChromeMetrics.RtModal.lightBackdropOpacity : ChromeMetrics.RtModal.darkBackdropOpacity)
            .contentShape(Rectangle())
            .onTapGesture { switcher.cancel() }
    }

    private func box(rows: [SwitcherLine<ID>], maxListHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(theme.rule).frame(height: ChromeMetrics.ruleWidth)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        // Highlighted by its index in `order`, the index
                        // letting go opens.
                        ForEach(rows, id: \.id) { line in
                            Button { open(line.id) } label: {
                                rowView(line.id, line.row, selected: line.index == switcher.selection)
                            }
                            .buttonStyle(.plain)
                            .id(line.id)
                        }
                    }
                    .padding(Metrics.listPadding)
                }
                .scrollIndicators(.never)
                .frame(maxHeight: maxListHeight)
                .fixedSize(horizontal: false, vertical: true)
                .onChange(of: switcher.selection, initial: true) { _, _ in
                    if let id = switcher.selected { proxy.scrollTo(id, anchor: .center) }
                }
            }
            Rectangle().fill(theme.rule).frame(height: ChromeMetrics.ruleWidth)
            footer
        }
        .frame(width: width)
        .background(theme.chrome)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: Metrics.cornerRadius).strokeBorder(theme.rule, lineWidth: ChromeMetrics.ruleWidth))
        .shadow(color: .black.opacity(Metrics.shadowOpacity), radius: Metrics.shadowRadius, y: Metrics.shadowY)
        .accessibilityIdentifier(accessibilityPrefix)
    }

    private func rowView(_ id: ID, _ item: SwitcherRow, selected: Bool) -> some View {
        HStack(spacing: Metrics.rowGap) {
            if item.isEmptyPin {
                Color.clear.frame(width: ChromeMetrics.WorkspaceRow.statusDot, height: ChromeMetrics.WorkspaceRow.statusDot)
            } else {
                StatusDot(status: item.status, theme: theme, size: ChromeMetrics.WorkspaceRow.statusDot)
            }
            Text(item.label)
                .font(selected ? ChromeType.paletteNameSelected : ChromeType.paletteName)
                .foregroundStyle(item.isEmptyPin ? theme.textLabel.opacity(ChromeMetrics.WorkspaceRow.emptyPinOpacity) : theme.textStrong)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 0)
            if let chat = item.chat {
                HStack(spacing: ChromeMetrics.Switcher.chatGap) {
                    Image(systemName: "bubble.left.fill")
                        .font(ChromeType.switcherChatGlyph)
                    Text(chat)
                        .font(ChromeType.paletteShortcut)
                        .lineLimit(1)
                }
                .foregroundStyle(theme.textLabel)
                .padding(.trailing, ChromeMetrics.Switcher.chatCountGap)
            }
            if !item.isEmptyPin {
                Text("\(item.count)")
                    .font(ChromeType.paletteShortcut)
                    .foregroundStyle(theme.textLabel)
            }
        }
        .padding(.horizontal, Metrics.rowPadding + 2)
        .frame(height: Metrics.rowHeight)
        .background(RoundedRectangle(cornerRadius: Metrics.rowCornerRadius).fill(selected ? theme.selection : .clear))
        .hoverWash(theme, cornerRadius: Metrics.rowCornerRadius)
        .contentShape(Rectangle())
        .accessibilityIdentifier("\(accessibilityPrefix).row.\(id.rawValue)")
    }

    private var header: some View {
        HStack(spacing: Metrics.rowGap) {
            Text(heading.uppercased())
                .font(ChromeType.railHeading)
                .tracking(ChromeType.railHeadingTracking)
                .foregroundStyle(theme.textLabel)
            Spacer(minLength: 0)
            if let scope = scope() {
                Text(scope)
                    .font(ChromeType.paletteFooter)
                    .foregroundStyle(theme.textLabel)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, Metrics.searchPadding)
        .frame(height: ChromeMetrics.Switcher.headerHeight)
        .accessibilityIdentifier("\(accessibilityPrefix).header")
    }

    private var footer: some View {
        let glyph = switch trigger {
        case .control: "⌃"
        case .option: "⌥"
        }
        return HStack(spacing: Metrics.footerGap) {
            ForEach(["⇥ next", "⇧⇥ back", "release \(glyph) to open", "esc cancel"], id: \.self) { hint in
                Text(hint).font(ChromeType.paletteFooter).foregroundStyle(theme.textLabel)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metrics.searchPadding)
        .frame(height: Metrics.footerHeight)
    }

    private func open(_ id: ID) {
        switcher.select(id)
        if let target = switcher.finish() { go(target) }
    }
}
