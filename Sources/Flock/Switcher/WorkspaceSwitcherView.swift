import FlockCore
import SwiftUI

/// ⌃Tab's panel over the tab area: the workspaces most recently used first,
/// the one letting go of ⌃ will open selected. Draws nothing until the
/// switcher shows, so a quick tap never flashes it; the key monitor that
/// starts it lives as long as the tab area does.
struct WorkspaceSwitcherView: View {
    let theme: Theme
    let viewModel: SessionViewModel

    @Environment(WorkspaceSwitcher.self) private var switcher
    @Environment(CommandPaletteState.self) private var commandPalette
    @State private var monitor = WorkspaceSwitcherMonitor()

    private typealias Metrics = ChromeMetrics.Palette

    var body: some View {
        ZStack {
            if switcher.isShown {
                let rows = switcher.order.compactMap { id in viewModel.model?.workspaces.first { $0.workspaceID == id } }
                GeometryReader { proxy in
                    ZStack(alignment: .top) {
                        scrim
                        box(rows: rows)
                            .padding(.top, ChromeMetrics.Switcher.top(inTabAreaHeight: proxy.size.height, rowCount: rows.count))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            let palette = commandPalette
            monitor.install(
                switcher: switcher,
                blocked: { [viewModel] in palette.isOpen || viewModel.renameEditorIsOnScreen || viewModel.rt.modal != nil },
                begin: begin,
                open: { go(switcher.finish()) }
            )
        }
        .onDisappear { monitor.remove() }
    }

    private func begin(reverse: Bool) {
        let started = switcher.begin(
            workspaces: viewModel.model?.workspaces.map(\.workspaceID) ?? [],
            current: viewModel.selectedWorkspaceID, reverse: reverse
        )
        guard started else { return }
        let session = switcher.session
        Task {
            try? await Task.sleep(for: ChromeMetrics.Switcher.showDelay)
            switcher.show(session: session)
        }
    }

    private func go(_ target: WorkspaceID?) {
        guard let target else { return }
        Task { await viewModel.jumpToHerdr(workspace: target) }
    }

    private var scrim: some View {
        let isLight = ChromeRoles.isLight(panelBg: theme.palette.panelBg)
        return Color.black
            .opacity(isLight ? ChromeMetrics.RtModal.lightBackdropOpacity : ChromeMetrics.RtModal.darkBackdropOpacity)
            .contentShape(Rectangle())
            .onTapGesture { switcher.cancel() }
    }

    private func box(rows: [WorkspaceRecord]) -> some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(rows.enumerated()), id: \.element.workspaceID) { index, workspace in
                            Button { open(workspace.workspaceID) } label: {
                                rowView(workspace, selected: index == switcher.selection)
                            }
                            .buttonStyle(.plain)
                            .id(workspace.workspaceID)
                        }
                    }
                    .padding(Metrics.listPadding)
                }
                .scrollIndicators(.automatic)
                .frame(maxHeight: Metrics.maxListHeight)
                .fixedSize(horizontal: false, vertical: true)
                .onChange(of: switcher.selection, initial: true) { _, _ in
                    if let id = switcher.selected { proxy.scrollTo(id) }
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
        .accessibilityIdentifier("flock.switcher")
    }

    private func rowView(_ workspace: WorkspaceRecord, selected: Bool) -> some View {
        HStack(spacing: Metrics.rowGap) {
            StatusDot(status: workspace.agentStatus, theme: theme, size: ChromeMetrics.WorkspaceRow.statusDot)
            Text(workspace.label)
                .font(selected ? ChromeType.paletteNameSelected : ChromeType.paletteName)
                .foregroundStyle(theme.textStrong)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text("\(viewModel.paneCount(for: workspace.workspaceID))")
                .font(ChromeType.paletteShortcut)
                .foregroundStyle(theme.textLabel)
        }
        .padding(.horizontal, Metrics.rowPadding + 2)
        .frame(height: Metrics.rowHeight)
        .background(RoundedRectangle(cornerRadius: Metrics.rowCornerRadius).fill(selected ? theme.selection : .clear))
        .hoverWash(theme, cornerRadius: Metrics.rowCornerRadius)
        .contentShape(Rectangle())
        .accessibilityIdentifier("flock.switcher.row.\(workspace.workspaceID.rawValue)")
    }

    private var footer: some View {
        HStack(spacing: Metrics.footerGap) {
            ForEach(["⇥ next", "⇧⇥ back", "release ⌃ to open", "esc cancel"], id: \.self) { hint in
                Text(hint).font(ChromeType.paletteFooter).foregroundStyle(theme.textLabel)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metrics.searchPadding)
        .frame(height: Metrics.footerHeight)
    }

    private func open(_ id: WorkspaceID) {
        switcher.select(id)
        go(switcher.finish())
    }
}
