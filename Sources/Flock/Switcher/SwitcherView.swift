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

    var body: some View {
        let palette = commandPalette
        let busy = { [viewModel] in palette.isOpen || viewModel.renameEditorIsOnScreen || viewModel.rt.modal != nil }
        ZStack {
            SwitcherView(
                theme: theme, switcher: workspaces, trigger: .control, accessibilityPrefix: "flock.switcher",
                row: { [viewModel] id in
                    viewModel.model?.workspaces.first { $0.workspaceID == id }.map {
                        SwitcherRow(status: $0.agentStatus, label: $0.label, count: viewModel.paneCount(for: id))
                    }
                },
                candidates: { [viewModel] in
                    WorkspaceSwitcher.candidates(viewModel.model?.workspaces ?? [], current: viewModel.selectedWorkspaceID)
                },
                current: { [viewModel] in viewModel.selectedWorkspaceID },
                blocked: { [tabs] in busy() || tabs.isActive },
                go: { [viewModel] id in Task { await viewModel.jumpToHerdr(workspace: id) } }
            )
            SwitcherView(
                theme: theme, switcher: tabs, trigger: .option, accessibilityPrefix: "flock.tabSwitcher",
                row: { [viewModel] id in
                    guard let model = viewModel.model, let tab = viewModel.tabsForSelectedWorkspace.first(where: { $0.tabID == id })
                    else { return nil }
                    return SwitcherRow(status: tab.agentStatus, label: TabSwitcher.title(for: tab, in: model), count: tab.paneCount)
                },
                candidates: { [viewModel] in viewModel.tabsForSelectedWorkspace.map(\.tabID) },
                current: { [viewModel] in viewModel.selectedTabID },
                blocked: { [workspaces] in busy() || workspaces.isActive },
                go: { [viewModel] id in Task { await viewModel.jumpToHerdr(tab: id) } }
            )
        }
    }
}

struct SwitcherRow {
    let status: AgentStatus
    let label: String
    let count: Int
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
    let row: (ID) -> SwitcherRow?
    let candidates: () -> [ID]
    let current: () -> ID?
    let blocked: () -> Bool
    let go: (ID) -> Void

    @State private var monitor = SwitcherMonitor<ID>()

    private typealias Metrics = ChromeMetrics.Palette

    var body: some View {
        ZStack {
            if switcher.isShown {
                let rows = switcher.order.compactMap { id in row(id).map { (id, $0) } }
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

    private func begin(reverse: Bool) {
        guard switcher.begin(items: candidates(), current: current(), reverse: reverse) else { return }
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

    private func box(rows: [(ID, SwitcherRow)], maxListHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(rows.enumerated()), id: \.element.0) { index, item in
                            Button { open(item.0) } label: {
                                rowView(item.0, item.1, selected: index == switcher.selection)
                            }
                            .buttonStyle(.plain)
                            .id(item.0)
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
        .frame(width: ChromeMetrics.Switcher.width)
        .background(theme.chrome)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: Metrics.cornerRadius).strokeBorder(theme.rule, lineWidth: ChromeMetrics.ruleWidth))
        .shadow(color: .black.opacity(Metrics.shadowOpacity), radius: Metrics.shadowRadius, y: Metrics.shadowY)
        .accessibilityIdentifier(accessibilityPrefix)
    }

    private func rowView(_ id: ID, _ item: SwitcherRow, selected: Bool) -> some View {
        HStack(spacing: Metrics.rowGap) {
            StatusDot(status: item.status, theme: theme, size: ChromeMetrics.WorkspaceRow.statusDot)
            Text(item.label)
                .font(selected ? ChromeType.paletteNameSelected : ChromeType.paletteName)
                .foregroundStyle(theme.textStrong)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text("\(item.count)")
                .font(ChromeType.paletteShortcut)
                .foregroundStyle(theme.textLabel)
        }
        .padding(.horizontal, Metrics.rowPadding + 2)
        .frame(height: Metrics.rowHeight)
        .background(RoundedRectangle(cornerRadius: Metrics.rowCornerRadius).fill(selected ? theme.selection : .clear))
        .hoverWash(theme, cornerRadius: Metrics.rowCornerRadius)
        .contentShape(Rectangle())
        .accessibilityIdentifier("\(accessibilityPrefix).row.\(id.rawValue)")
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
