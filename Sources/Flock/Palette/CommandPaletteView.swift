import FlockCore
import SwiftUI

/// The command palette over the tab area: a scrim that closes it on a click,
/// and near the top a box holding the search field, the rows and a footer.
/// Draws nothing while closed.
struct CommandPaletteView: View {
    let theme: Theme
    let viewModel: SessionViewModel

    @Environment(CommandPaletteState.self) private var state
    @Environment(PaletteRecentsStore.self) private var recents
    @Environment(ChatStore.self) private var chatStore
    @Environment(RearrangeMode.self) private var rearrangeMode
    @Environment(DragCoordinator.self) private var dragCoordinator
    @FocusState private var searchFocused: Bool

    var rtInstalled = RtAvailability.installed

    private typealias Metrics = ChromeMetrics.Palette

    var body: some View {
        if state.isOpen {
            let entries = PaletteCatalog.entries(
                in: .current(viewModel: viewModel, chatStore: chatStore, rtInstalled: rtInstalled)
            )
            let rows = PaletteRanking.rows(commands: entries.map(\.command), query: state.query, recents: recents.ids)
            ZStack(alignment: .top) {
                scrim
                box(rows: rows, entries: entries)
                    .padding(.top, Metrics.top)
            }
            .background(PaletteKeyMonitor(editorIsOpen: viewModel.renameEditorIsOnScreen) { decision in
                handle(decision, rows: rows, entries: entries)
            })
            .onChange(of: rows.count, initial: true) { _, count in state.clampSelection(rowCount: count) }
            .onAppear { searchFocused = true }
        }
    }

    private var scrim: some View {
        let isLight = ChromeRoles.isLight(panelBg: theme.palette.panelBg)
        return Color.black
            .opacity(isLight ? ChromeMetrics.RtModal.lightBackdropOpacity : ChromeMetrics.RtModal.darkBackdropOpacity)
            .contentShape(Rectangle())
            .onTapGesture { state.close() }
    }

    private func box(rows: [PaletteRanking.Row], entries: [PaletteEntry]) -> some View {
        VStack(spacing: 0) {
            search
            Rectangle().fill(theme.rule).frame(height: ChromeMetrics.ruleWidth)
            list(rows: rows, entries: entries)
            Rectangle().fill(theme.rule).frame(height: ChromeMetrics.ruleWidth)
            footer
        }
        .frame(width: Metrics.width)
        .background(theme.chrome)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: Metrics.cornerRadius).strokeBorder(theme.rule, lineWidth: ChromeMetrics.ruleWidth))
        .shadow(color: .black.opacity(Metrics.shadowOpacity), radius: Metrics.shadowRadius, y: Metrics.shadowY)
        .accessibilityIdentifier("flock.palette")
    }

    private var search: some View {
        @Bindable var state = state
        return HStack(spacing: Metrics.searchGap) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: Metrics.searchIcon - 2))
                .foregroundStyle(theme.textLabel)
            TextField("", text: $state.query)
                .textFieldStyle(.plain)
                .font(ChromeType.paletteSearch)
                .foregroundStyle(theme.textStrong)
                .focused($searchFocused)
                // Drawn here rather than as the field's prompt, which takes
                // the window's appearance and not the theme: a light theme
                // under a dark system appearance painted it near white.
                .overlay(alignment: .leading) {
                    if state.query.isEmpty {
                        Text("Search commands")
                            .font(ChromeType.paletteSearch)
                            .foregroundStyle(theme.textLabel)
                            .allowsHitTesting(false)
                    }
                }
                .accessibilityIdentifier("flock.palette.search")
        }
        .padding(.horizontal, Metrics.searchPadding)
        .frame(height: Metrics.searchHeight)
    }

    @ViewBuilder
    private func list(rows: [PaletteRanking.Row], entries: [PaletteEntry]) -> some View {
        if rows.isEmpty {
            Text("No matching commands")
                .font(ChromeType.paletteName)
                .foregroundStyle(theme.textLabel)
                .frame(maxWidth: .infinity, minHeight: Metrics.rowHeight * 2)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            if row.section != nil, index == 0 || rows[index - 1].section != row.section {
                                section(row.section == .recent ? "RECENT" : "ALL COMMANDS")
                            }
                            // A button rather than a tap gesture: it takes the
                            // click that also makes an inactive window key.
                            Button { runRow(at: index, rows: rows, entries: entries) } label: {
                                rowView(row, selected: index == state.selectedIndex(rowCount: rows.count))
                            }
                            .buttonStyle(.plain)
                            .id(row.id)
                        }
                    }
                    .padding(Metrics.listPadding)
                }
                // A legacy scroller's gutter would pull the shortcut column in
                // from the box's edge whenever the list overflows.
                .scrollIndicators(.never)
                .frame(maxHeight: Metrics.maxListHeight)
                .fixedSize(horizontal: false, vertical: true)
                .onChange(of: state.selection) { _, _ in
                    guard let index = state.selectedIndex(rowCount: rows.count) else { return }
                    proxy.scrollTo(rows[index].id)
                }
            }
        }
    }

    private func section(_ title: String) -> some View {
        Text(title)
            .font(ChromeType.paletteSection)
            .tracking(0.8)
            .foregroundStyle(theme.textLabel)
            .padding(Metrics.sectionPadding)
    }

    private func rowView(_ row: PaletteRanking.Row, selected: Bool) -> some View {
        HStack(spacing: Metrics.rowGap) {
            Text(row.command.namespace.rawValue)
                .font(ChromeType.paletteBadge)
                .foregroundStyle(theme.textLabel)
                .frame(width: Metrics.badgeSize.width, height: Metrics.badgeSize.height)
                .background(RoundedRectangle(cornerRadius: Metrics.badgeCornerRadius).fill(badgeFill))
            highlighted(row)
                .font(selected ? ChromeType.paletteNameSelected : ChromeType.paletteName)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let trailing = row.command.shortcut ?? row.command.hint {
                Text(trailing).font(ChromeType.paletteShortcut).foregroundStyle(theme.textLabel)
            }
        }
        .padding(.horizontal, Metrics.rowPadding)
        .frame(height: Metrics.rowHeight)
        .background(RoundedRectangle(cornerRadius: Metrics.rowCornerRadius).fill(selected ? theme.selection : .clear))
        .hoverWash(theme, cornerRadius: Metrics.rowCornerRadius)
        .contentShape(Rectangle())
        .accessibilityIdentifier("flock.palette.row.\(row.command.id)")
    }

    private var badgeFill: Color {
        ChromeRoles.isLight(panelBg: theme.palette.panelBg) ? Color(theme.palette.surface1) : Color(theme.palette.surface0)
    }

    private func highlighted(_ row: PaletteRanking.Row) -> Text {
        let matched = Set(row.nameIndices)
        var text = AttributedString()
        for (offset, character) in row.command.name.enumerated() {
            var piece = AttributedString(String(character))
            piece.foregroundColor = matched.contains(offset) ? theme.accent : theme.textStrong
            text += piece
        }
        return Text(text)
    }

    private var footer: some View {
        HStack(spacing: Metrics.footerGap) {
            ForEach(["↑↓ move", "↵ run", "esc close"], id: \.self) { hint in
                Text(hint).font(ChromeType.paletteFooter).foregroundStyle(theme.textLabel)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metrics.searchPadding)
        .frame(height: Metrics.footerHeight)
    }

    private func handle(_ decision: PaletteKey.Decision, rows: [PaletteRanking.Row], entries: [PaletteEntry]) {
        switch decision {
        case .up: state.move(-1, rowCount: rows.count)
        case .down: state.move(1, rowCount: rows.count)
        case .close: state.close()
        case .run:
            guard let index = state.selectedIndex(rowCount: rows.count) else { return }
            runRow(at: index, rows: rows, entries: entries)
        case .pass: break
        }
    }

    /// Closed before the action runs, so a command that opens its own UI
    /// (the rename editor, a chat popover) gets the focus.
    private func runRow(at index: Int, rows: [PaletteRanking.Row], entries: [PaletteEntry]) {
        guard rows.indices.contains(index), let entry = entries.first(where: { $0.command.id == rows[index].command.id }) else { return }
        state.close()
        recents.record(entry.command.id)
        PaletteRunner(viewModel: viewModel, chatStore: chatStore, rearrangeMode: rearrangeMode, dragCoordinator: dragCoordinator)
            .run(entry.action)
    }
}
