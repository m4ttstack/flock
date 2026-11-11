import FlockCore
import SwiftUI

/// The hold-and-tap switchers over the tab area: ⌃Tab's workspaces, ⌥Tab's
/// tabs in the selected workspace and ⌘`'s agents in every workspace. Each
/// blocks the others, and ⌃`'s profiles and ⌥`'s servers block all three,
/// while any is up.
struct SwitcherOverlay: View {
    let theme: Theme
    let viewModel: SessionViewModel

    @Environment(WorkspaceSwitcher.self) private var workspaces
    @Environment(TabSwitcher.self) private var tabs
    @Environment(AgentSwitcher.self) private var agents
    @Environment(CommandPaletteState.self) private var commandPalette
    @Environment(ChatStore.self) private var chatStore
    @Environment(ProfileSwitcher.self) private var profiles: ProfileSwitcher?
    @Environment(ServerSwitcher.self) private var servers: ServerSwitcher?
    @Environment(ProfilePickerContext.self) private var profilePicker: ProfilePickerContext?

    var body: some View {
        let palette = commandPalette
        let blockers = { [viewModel, workspaces, tabs, agents, profiles, servers, profilePicker] in
            SwitcherBlockers(
                paletteOpen: palette.isOpen, renaming: viewModel.renameEditorIsOnScreen, rtModal: viewModel.rt.modal != nil,
                profilePickerOpen: profilePicker?.isOpen ?? false,
                active: SwitcherKind.active(workspaces: workspaces, tabs: tabs, profiles: profiles, servers: servers, agents: agents)
            )
        }
        ZStack {
            SwitcherView(
                theme: theme, switcher: workspaces, trigger: .controlTab, accessibilityPrefix: "flock.switcher",
                heading: "Workspaces",
                row: { [viewModel] id in Self.workspaceRow(id, viewModel: viewModel) },
                candidates: { [viewModel] in Self.workspaceCandidates(viewModel: viewModel) },
                current: { [viewModel] in viewModel.selectedWorkspaceID },
                blocked: { blockers().blocks(.workspaces) },
                go: { [viewModel] id in
                    Task {
                        if let pin = PinID(switcherID: id) {
                            if viewModel.pins.pin(pin)?.placement == .topBar {
                                await viewModel.toggleTopBar(pin)
                            } else {
                                viewModel.show(emptyPin: pin)
                            }
                        } else {
                            await viewModel.jumpToHerdr(workspace: id)
                        }
                    }
                }
            )
            // Chat's names only where chat runs at all: without herdr-chat or
            // rt the box keeps its narrow width and no row asks after anyone.
            let chat = chatStore.isAvailable ? chatStore : nil
            SwitcherView(
                theme: theme, switcher: tabs, trigger: .optionTab, accessibilityPrefix: "flock.tabSwitcher",
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
                blocked: { blockers().blocks(.tabs) },
                go: { [viewModel] id in Task { await viewModel.jumpToHerdr(tab: id) } }
            )
            SwitcherView(
                theme: theme, switcher: agents, trigger: .commandBacktick, accessibilityPrefix: "flock.agentSwitcher",
                heading: "Agents",
                width: ChromeMetrics.Switcher.chatWidth,
                row: { [viewModel] id in Self.agentRow(id, viewModel: viewModel, chat: chat) },
                onBegin: { if let chat { Task { await chat.refreshBuddies() } } },
                candidates: { [viewModel] in viewModel.model.map(AgentSwitcher.candidates(in:)) ?? [] },
                current: { [viewModel] in viewModel.resolvedFocusedPaneID },
                blocked: { blockers().blocks(.agents) },
                go: { [viewModel] id in Task { await viewModel.jumpToPane(id) } }
            )
        }
    }

    /// Named as chat names the agent when it is signed in, with its face;
    /// otherwise by its pane's title.
    static func agentRow(_ id: PaneID, viewModel: SessionViewModel, chat: ChatStore?) -> SwitcherRow? {
        guard let model = viewModel.model, let pane = model.panes[id], pane.agent != nil else { return nil }
        let buddy = chat?.buddies[id]
        return SwitcherRow(
            status: pane.agentStatus, label: buddy?.displayName ?? pane.displayTitle, count: 0,
            face: buddy.map { SwitcherRow.Face(name: $0.displayName, handle: $0.handle) }, agent: pane.agent,
            detail: AgentSwitcher.location(of: pane, in: model) ?? ""
        )
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

extension SwitcherKind {
    @MainActor
    static func active(
        workspaces: WorkspaceSwitcher?, tabs: TabSwitcher?, profiles: ProfileSwitcher?, servers: ServerSwitcher?,
        agents: AgentSwitcher?
    ) -> Set<SwitcherKind> {
        var active: Set<SwitcherKind> = []
        if workspaces?.isActive == true { active.insert(.workspaces) }
        if tabs?.isActive == true { active.insert(.tabs) }
        if profiles?.isActive == true { active.insert(.profiles) }
        if servers?.isActive == true { active.insert(.servers) }
        if agents?.isActive == true { active.insert(.agents) }
        return active
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
    /// Drawn as the profile picker draws a profile: a machine's marker where
    /// the status dot goes, the current machine's connection dot after the
    /// name, no count.
    var profile: Profile? = nil
    /// Drawn as Settings' Server menu draws a server: a check on the current
    /// one where the status dot goes, its running state where the count goes.
    var server: ServerSwitcherRow? = nil
    /// A signed-in agent's chat face, drawn before its name.
    var face: Face? = nil
    /// The agent herdr detected, whose mark fills the face's slot when chat
    /// has no face for it.
    var agent: String? = nil
    /// Drawn where the count goes, in its place.
    var detail: String? = nil

    struct Face {
        let name: String
        let handle: String
    }

    struct Profile {
        let isMachine: Bool
        let dot: ProfileConnectionDot?
    }

    static func emptyPin(label: String) -> SwitcherRow {
        SwitcherRow(status: .unknown, label: label, count: 0, isEmptyPin: true)
    }

    static func server(_ row: ServerSwitcherRow) -> SwitcherRow {
        SwitcherRow(status: .unknown, label: row.label, count: 0, server: row)
    }

    static func profile(_ row: ProfilePickerRow) -> SwitcherRow {
        SwitcherRow(status: .unknown, label: row.title, count: 0, profile: Profile(isMachine: row.isMachine, dot: row.dot))
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
/// lives as long as the view does.
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
    /// Candidates offered after all the others; see `RecentsSwitcher.begin`.
    var last: () -> Set<ID> = { [] }
    let current: () -> ID?
    let blocked: () -> Bool
    let go: (ID) -> Void

    @State private var monitor = SwitcherMonitor<ID>()

    private typealias Metrics = ChromeMetrics.Palette

    var body: some View {
        ZStack {
            if switcher.isShown {
                let rows = switcher.order.enumerated().compactMap { index, id in row(id).map { SwitcherLine(index: index, id: id, row: $0) } }
                let lineCount = rows.count + (switcher.isEmpty ? 1 : 0)
                GeometryReader { proxy in
                    ZStack(alignment: .top) {
                        scrim
                        box(rows: rows, maxListHeight: ChromeMetrics.Switcher.maxListHeight(inTabAreaHeight: proxy.size.height))
                            .padding(.top, ChromeMetrics.Switcher.top(inTabAreaHeight: proxy.size.height, rowCount: lineCount))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            monitor.install(
                switcher: switcher, trigger: trigger, blocked: blocked, begin: begin,
                open: { finish() }
            )
        }
        // A switcher held open by a monitor that is gone would block the
        // others until the app next resigns.
        .onDisappear {
            monitor.remove()
            switcher.cancel()
        }
    }

    /// Only items that draw a row are offered, so `selection`, which counts
    /// `order`, counts the rows as drawn.
    func begin(reverse: Bool) {
        let items = candidates().filter { row($0) != nil }
        switcher.begin(items: items, current: current(), reverse: reverse, last: last())
        onBegin()
        let session = switcher.session
        if switcher.isEmpty { return }
        Task {
            try? await Task.sleep(for: ChromeMetrics.Switcher.showDelay)
            switcher.show(session: session)
        }
    }

    private var scrim: some View {
        let isLight = ChromeRoles.isLight(panelBg: theme.palette.panelBg)
        return Color.black
            .opacity(isLight ? ChromeMetrics.Modal.lightBackdropOpacity : ChromeMetrics.Modal.darkBackdropOpacity)
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
                        if switcher.isEmpty {
                            Text("No \(rows.isEmpty ? "" : "other ")\(heading.lowercased())")
                                .font(ChromeType.paletteName)
                                .foregroundStyle(theme.textLabel)
                                .padding(.horizontal, Metrics.rowPadding + 2)
                                .frame(height: Metrics.rowHeight)
                                .accessibilityIdentifier("\(accessibilityPrefix).empty")
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
            if let server = item.server {
                Image(systemName: "checkmark")
                    .font(ChromeType.switcherCheck)
                    .foregroundStyle(theme.textStrong)
                    .frame(width: ChromeMetrics.Switcher.checkWidth)
                    .opacity(server.isCurrent ? 1 : 0)
            } else if let profile = item.profile {
                if profile.isMachine {
                    ProfileMachineMarker(theme: theme)
                } else {
                    Color.clear.frame(width: ChromeMetrics.ProfilePicker.marker, height: ChromeMetrics.ProfilePicker.marker)
                }
            } else if item.isEmptyPin {
                Color.clear.frame(width: ChromeMetrics.WorkspaceRow.statusDot, height: ChromeMetrics.WorkspaceRow.statusDot)
            } else {
                StatusDot(status: item.status, theme: theme, size: ChromeMetrics.WorkspaceRow.statusDot)
            }
            if let face = item.face {
                SwitcherFace(theme: theme, face: face)
            } else if let agent = item.agent {
                AgentMarkFace(theme: theme, agent: agent)
            }
            Text(item.label)
                .font(selected ? ChromeType.paletteNameSelected : ChromeType.paletteName)
                .foregroundStyle(item.isEmptyPin ? theme.textLabel.opacity(ChromeMetrics.WorkspaceRow.emptyPinOpacity) : theme.textStrong)
                .lineLimit(1)
                .layoutPriority(1)
            if let dot = item.profile?.dot {
                ProfileDot(theme: theme, dot: dot)
            }
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
            if let detail = item.detail {
                Text(detail)
                    .font(ChromeType.paletteShortcut)
                    .foregroundStyle(theme.textLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else if let status = item.server?.status {
                Text(status)
                    .font(ChromeType.paletteShortcut)
                    .foregroundStyle(theme.textLabel)
            } else if !item.isEmptyPin, item.profile == nil, item.server == nil {
                Text("\(item.count)")
                    .font(ChromeType.paletteShortcut)
                    .foregroundStyle(theme.textLabel)
            }
        }
        .padding(.horizontal, Metrics.rowPadding + 2)
        .frame(height: Metrics.rowHeight)
        .background(RoundedRectangle(cornerRadius: Metrics.rowCornerRadius).fill(selected ? theme.lift : .clear))
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
        HStack(spacing: Metrics.footerGap) {
            hint(keys: [trigger.keyGlyph], after: "next")
            hint(keys: ["\u{2191}", "\u{2193}"], after: "move")
            hint(before: "release", keys: [trigger.modifierGlyph], after: "to open")
            hint(keys: [trigger.cancelGlyph], after: "cancel")
            Spacer(minLength: 0)
        }
        .font(ChromeType.paletteFooter)
        .foregroundStyle(theme.textLabel)
        .padding(.horizontal, Metrics.searchPadding)
        .frame(height: Metrics.footerHeight)
    }

    private func hint(before: String? = nil, keys: [String], after: String) -> some View {
        HStack(spacing: ChromeMetrics.Switcher.keycapLabelGap) {
            if let before { Text(before) }
            HStack(spacing: ChromeMetrics.Switcher.keycapGap) {
                ForEach(keys, id: \.self) { keycap($0) }
            }
            Text(after)
        }
    }

    private func keycap(_ glyph: String) -> some View {
        typealias Switcher = ChromeMetrics.Switcher
        let isBacktick = glyph == SwitcherTrigger.controlBacktick.keyGlyph
        let shape = RoundedRectangle(cornerRadius: ChromeRadius.tiny)
        return Group {
            if isBacktick {
                BacktickStroke()
                    .stroke(style: StrokeStyle(lineWidth: Switcher.backtickWeight, lineCap: .round))
                    .frame(width: Switcher.backtickWidth, height: Switcher.backtickHeight)
                    .offset(y: -Switcher.backtickRise)
            } else if glyph == "." {
                Circle().frame(width: Switcher.periodSize, height: Switcher.periodSize)
                    .offset(y: Switcher.periodDrop)
            } else {
                Text(verbatim: glyph).font(ChromeType.switcherKeycap)
            }
        }
            .padding(.horizontal, glyph.count > 1 ? Switcher.keycapPadding : 0)
            .frame(minWidth: Switcher.keycapHeight, minHeight: Switcher.keycapHeight, maxHeight: Switcher.keycapHeight)
            .background(shape.fill(theme.textLabel.opacity(Switcher.keycapFillOpacity)))
            .overlay(shape.strokeBorder(theme.rule, lineWidth: ChromeMetrics.ruleWidth))
            .clipShape(shape)
    }

    private func open(_ id: ID) {
        switcher.select(id)
        finish()
    }

    private func finish() {
        if let target = switcher.finish() {
            go(target)
        } else if switcher.isLingering {
            let session = switcher.session
            Task {
                try? await Task.sleep(for: ChromeMetrics.Switcher.emptyLinger)
                switcher.endLinger(session: session)
            }
        }
    }
}

/// An agent with no chat face: its harness's mark on the mark's own ground,
/// shaped as a face, or the agent's initial where flock has no mark.
private struct AgentMarkFace: View {
    let theme: Theme
    let agent: String

    private typealias M = ChromeMetrics.PaneBar

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: M.faceCornerRadius, style: .continuous)
        if let mark = HarnessMark.forAgent(agent), mark.cgPath != nil {
            shape
                .fill(Color(mark.ground))
                .frame(width: M.faceSize, height: M.faceSize)
                .overlay(MarkShape(mark: mark).fill(Color(mark.ink)).padding(M.faceSize * 0.2))
        } else {
            ChatFace(style: LauncherStripStyle(theme: theme), name: agent, image: nil)
        }
    }
}

/// A switcher row's chat face, followed as the pane bar's chip follows it.
private struct SwitcherFace: View {
    let theme: Theme
    let face: SwitcherRow.Face

    @Environment(ChatStore.self) private var chatStore: ChatStore?

    var body: some View {
        ChatFace(style: LauncherStripStyle(theme: theme), name: face.name, image: chatStore?.face(for: face.handle))
            .task(id: face.handle) { await chatStore?.followFace(face.handle) }
    }
}

/// The backtick as a keycap legend: the font's grave is a speck at keycap
/// size, so it is drawn as the key prints it, a short stroke falling right.
private struct BacktickStroke: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        }
    }
}
