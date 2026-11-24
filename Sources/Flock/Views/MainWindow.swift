import AppKit
import FlockCore
import SwiftUI

/// The whole window: title bar, workspace rail, tab strip, pane canvas.
/// Every color comes from the active theme's roles via the environment.
struct MainWindow: View {
    @Environment(ThemeStore.self) private var themeStore
    @Environment(DragCoordinator.self) private var dragCoordinator
    @Environment(RailWidthStore.self) private var railWidth
    @Environment(CommandPaletteState.self) private var commandPalette
    @Environment(WorkspaceSwitcher.self) private var switcher
    @Environment(TabSwitcher.self) private var tabSwitcher
    @Environment(AgentSwitcher.self) private var agentSwitcher
    @Environment(ProfileSwitcher.self) private var profileSwitcher: ProfileSwitcher?
    @Environment(ServerSwitcher.self) private var serverSwitcher: ServerSwitcher?
    @Environment(AllWorkspacesModeStore.self) private var allWorkspacesMode
    @Environment(BoardStore.self) private var boardStore
    @Environment(HerdProgressStore.self) private var herdProgress
    @Environment(OverviewInclusionStore.self) private var overviewInclusion: OverviewInclusionStore?
    @Environment(StartingFolderStore.self) private var startingFolders: StartingFolderStore?
    @Environment(ChatSidebarStore.self) private var chatSidebar: ChatSidebarStore?
    let viewModel: SessionViewModel
    let sessionLabel: String
    let herdrBuildStore: HerdrBuildStore
    var isDevBuild = BuildFlavor.isDev
    var machineNotice: MachineNotice? = nil

    private var theme: Theme { themeStore.active }

    /// The focused pane while it runs an agent, so an agent started in an
    /// already focused shell is noted too.
    private var focusedAgentPane: PaneID? {
        viewModel.resolvedFocusedPaneID.flatMap { viewModel.model?.panes[$0]?.agent != nil ? $0 : nil }
    }

    private var bannerConfirmation: HerdrBuildStore.PendingConfirmation? {
        herdrBuildStore.pendingConfirmation.flatMap { $0.source == .banner ? $0 : nil }
    }

    private var tabPanes: Set<String> {
        Set(viewModel.selectedLayout?.panes.map(\.paneID.rawValue) ?? [])
    }

    private var paletteSurface: PaletteSurface {
        JumpNavigator(viewModel: viewModel, drag: dragCoordinator, mode: allWorkspacesMode).paletteSurface
    }

    /// What Overview's Blocked group holds, so the badge counts only panes
    /// Overview shows.
    private var blockedCount: Int {
        guard let model = viewModel.model else { return 0 }
        let excluded = overviewInclusion.flatMap { inclusion in
            viewModel.railSections(board: boardStore.names, herdProgress: herdProgress.progress).map(inclusion.excluded(from:))
        } ?? []
        return MissionBoard.blockedCount(model: model.hiding(excluded), toasts: viewModel.attentionToasts)
    }

    @State private var titleBarTrailingWidth: CGFloat = 0
    @State private var chatSidebarWidth: CGFloat = 0

    @ViewBuilder
    private var banners: some View {
        if let banner = viewModel.unsupportedBanner {
            UnsupportedBanner(theme: theme, mismatch: banner)
        }
        // Below the protocol banner deliberately: a herdr too old to talk
        // to at all outranks an optional capability of one that works.
        // The build is this Mac's herdr, which a machine session's panes
        // do not run on.
        if viewModel.isRemoteMachine {
            EmptyView()
        } else if let reason = herdrBuildStore.bannerRestartPrompt {
            HerdrRestartBanner(theme: theme, store: herdrBuildStore, reason: reason)
        } else if herdrBuildStore.showsBanner {
            HerdrBuildBanner(theme: theme, store: herdrBuildStore)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if dragCoordinator.isGridShown {
                Color.clear.frame(height: ChromeMetrics.TitleBar.height)
                banners
                AllWorkspacesGrid(theme: theme, viewModel: viewModel)
                    // The grid covers the rail and its dock, so Arrange's
                    // notices float where the rail would be. Overview draws
                    // none: its Needs you lane holds the cards.
                    .overlay(alignment: .bottomLeading) {
                        if allWorkspacesMode.shown(dragInFlight: dragCoordinator.activeSubject != nil) == .arrange {
                            MessageDock(theme: theme, viewModel: viewModel, placement: .overGrid)
                                .frame(width: railWidth.width)
                        }
                    }
            } else {
                HStack(spacing: 0) {
                    WorkspaceRail(
                        theme: theme,
                        viewModel: viewModel,
                        onSelect: { id in Task { await viewModel.jumpToHerdr(workspace: id) } },
                        profileDot: viewModel.isRemoteMachine ? .forMachine(hasNotice: machineNotice != nil) : nil
                    )
                    .padding(.top, ChromeMetrics.TitleBar.height)
                    VStack(spacing: 0) {
                        if let pin = viewModel.shownEmptyPin.flatMap(viewModel.pins.pin) {
                            Color.clear.frame(height: ChromeMetrics.TitleBar.height)
                            banners
                            EmptyPinView(theme: theme, viewModel: viewModel, pin: pin)
                        } else if viewModel.showsStartScreen, let startingFolders {
                            Color.clear.frame(height: ChromeMetrics.TitleBar.height)
                            banners
                            StartScreenView(
                                theme: theme, viewModel: viewModel, folders: startingFolders,
                                serverName: sessionLabel == HerdrServerAddress.defaultServer.label ? nil : sessionLabel,
                                showsFolder: !viewModel.isRemoteMachine
                            )
                        } else {
                            // In the title bar's own row: the bar draws only
                            // its trailing cluster, which the strip stops short of.
                            TabStrip(
                                theme: theme,
                                viewModel: viewModel,
                                workspace: viewModel.selectedWorkspaceID,
                                tabs: viewModel.tabsForSelectedWorkspace,
                                selectedTabID: viewModel.selectedTabID,
                                onSelect: { id in Task { await viewModel.jumpToHerdr(tab: id) } }
                            )
                            .padding(.trailing, titleBarTrailingWidth)
                            banners
                            PaneCanvas(theme: theme, viewModel: viewModel, layout: viewModel.selectedLayout)
                        }
                    }
                    // On the tab area alone, so the rail stays clear and
                    // undimmed. The grid mounts its own (rt modal and
                    // palette) over a focused pane.
                    .overlay { RtModalView(theme: theme, viewModel: viewModel) }
                    .anchorPreference(key: TabAreaAnchor.self, value: .bounds) { $0 }
                    .overlay { CommandPaletteView(theme: theme, viewModel: viewModel) }
                    .overlay { SwitcherOverlay(theme: theme, viewModel: viewModel) }
                    if let chatSidebar {
                        ChatSidebar(theme: theme, store: chatSidebar)
                            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { chatSidebarWidth = $0 }
                            .onDisappear { chatSidebarWidth = 0 }
                    }
                }
            }
        }
        .modifier(ChatSidebarFollower(focusedPane: viewModel.resolvedFocusedPaneID, tabPanes: tabPanes))
        .background(theme.chrome)
        // Below the title bar and over everything else, rail included, so it
        // opens from any view and its icon can close it again.
        .overlayPreferenceValue(TabAreaAnchor.self) { tabArea in
            // Mounted only while open: a reader over the whole window would
            // otherwise sit over every click.
            if viewModel.topBarOverlay.openPin != nil {
                GeometryReader { proxy in
                    TopBarWorkspaceOverlay(theme: theme, viewModel: viewModel, cardArea: tabArea.map { proxy[$0] })
                }
                .padding(.top, ChromeMetrics.TitleBar.height)
            }
        }
        // Over the content rather than above it in the stack: the tab strip's
        // `NSScrollView` stretches up through the system title bar's safe
        // area to the window's top edge. Stacked, that scroll view sits over
        // the bar and takes its clicks.
        .overlay(alignment: .top) {
            TitleBar(
                theme: theme, sessionLabel: sessionLabel, connectionState: viewModel.connectionState,
                isDevBuild: isDevBuild, blockedCount: blockedCount, viewModel: viewModel,
                leadingDragWidth: dragCoordinator.isGridShown ? nil : railWidth.width,
                onTrailingWidth: { titleBarTrailingWidth = $0 },
                trailingReserve: chatSidebarWidth,
                machineNotice: machineNotice
            )
        }
        // What the rail's width is clamped against: a window too narrow for
        // the remembered rail shrinks it on screen, and widening the window
        // gives it back (`RailWidthStore`). A background reader rather than a
        // wrapping `GeometryReader`, which would take the layout over.
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { railWidth.windowResized(to: proxy.size.width) }
                    .onChange(of: proxy.size.width) { _, width in railWidth.windowResized(to: width) }
            }
        }
        // Names the one space every drag frame and drag point is expressed in
        // -- see `DragSpace`. Applied before the overlays so they resolve it
        // too, and so a rail/strip/canvas frame and a ghost position are
        // directly comparable.
        .coordinateSpace(.named(DragSpace.name))
        // Laid out at the named space's own frame, which is what lets a raw
        // AppKit event location be converted into it.
        .background(DragSpaceAnchor(coordinator: dragCoordinator))
        .overlay { DragLayer() }
        // Here, where both always render: each surface mounts its own
        // palette, and a rename editor on the live rail needs the Return and
        // Esc the palette would take.
        .onChange(of: dragCoordinator.isGridShown) { _, shown in
            if shown { switcher.cancel(); tabSwitcher.cancel(); agentSwitcher.cancel() }
        }
        .onChange(of: paletteSurface) { commandPalette.close() }
        .modifier(TopBarOverlayExclusion(viewModel: viewModel))
        // Here, where it runs once whichever view draws the stack: the dock,
        // or mission control's Needs you lane, which has no dock. It runs for
        // as long as anything is in the stack, not just while a finished
        // toast is counting down: the sweep is also what notices that a
        // "needs input" toast's coalescing grace has expired, and that toast
        // has no clock of its own.
        .task(id: viewModel.attentionToasts.isEmpty) {
            guard !viewModel.attentionToasts.isEmpty else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: ChromeMetrics.AttentionToast.sweepInterval)
                if Task.isCancelled { return }
                guard !viewModel.isAttentionStackHovered else { continue }
                viewModel.sweepAttentionToasts()
            }
        }
        .onChange(of: viewModel.renameEditorIsOnScreen) { _, renaming in
            if renaming {
                commandPalette.close()
                switcher.cancel()
                tabSwitcher.cancel()
                agentSwitcher.cancel()
                profileSwitcher?.cancel()
                serverSwitcher?.cancel()
            }
        }
        .onChange(of: viewModel.selectedWorkspaceID, initial: true) { _, id in
            if let id { switcher.note(id) }
        }
        .onChange(of: viewModel.selectedTabID, initial: true) { _, id in
            if let id { tabSwitcher.note(id) }
        }
        .onChange(of: focusedAgentPane, initial: true) { _, id in
            if let id { agentSwitcher.note(id) }
        }

        .frame(minWidth: 900, minHeight: 560)
        .ignoresSafeArea(edges: .top)
        .background(TitlebarConfigurator(windowBg: theme.chrome))
        .modifier(GroupCloseCard(theme: theme, viewModel: viewModel))
        .modifier(CloseWarningCard(theme: theme, viewModel: viewModel))
        .modifier(TopBarRefusalCard(theme: theme, viewModel: viewModel))
        .modifier(HerdrBuildBannerCard(theme: theme, store: herdrBuildStore, pending: bannerConfirmation))
    }
}

/// herdr refuses a plain close on a workspace that is a worktree group's
/// primary; this is that refusal, asked rather than reported.
private struct GroupCloseCard: ViewModifier {
    let theme: Theme
    let viewModel: SessionViewModel

    func body(content: Content) -> some View {
        content.modifier(ConfirmCardPresenter(
            theme: theme,
            item: viewModel.pendingGroupClose,
            content: { pending in
                ConfirmCardContent(
                    action: "Close Workspace and Worktrees",
                    name: pending.label,
                    nameSymbol: "square.stack",
                    // The busy sentence is absent when nothing is, so a quiet
                    // workspace reads as it always did.
                    message: AttributedString(
                        (["herdr keeps this workspace and its linked worktree workspaces together. Closing it closes all of them.",
                          pending.busy.groupSentence] as [String?]).compactMap { $0 }.joined(separator: " ")
                    ),
                    confirmTitle: "Close Group",
                    identifier: "flock.workspace.closeGroup"
                )
            },
            answer: { pending, answer in
                if answer.confirmed {
                    Task { await viewModel.confirmGroupClose(pending.workspaceID) }
                } else {
                    viewModel.cancelPendingGroupClose()
                }
            }
        ))
    }
}

private struct TopBarRefusalCard: ViewModifier {
    let theme: Theme
    let viewModel: SessionViewModel

    func body(content: Content) -> some View {
        content.modifier(ConfirmCardPresenter(
            theme: theme,
            item: viewModel.topBarRefusal,
            content: { refusal in
                ConfirmCardContent(
                    action: refusal.title, message: AttributedString(refusal.message),
                    cancelTitle: nil, confirmTitle: "OK", identifier: "flock.topBar.refusal"
                )
            },
            answer: { _, _ in viewModel.dismissTopBarRefusal() }
        ))
    }
}

/// The same confirmation the settings row raises, hosted here too so the
/// banner's Install is the identical action rather than a shortcut around it.
/// Naming the exact path being replaced is the point of it, so it is shown
/// every time. Only the banner's own requests: the Settings row presents its
/// own.
private struct HerdrBuildBannerCard: ViewModifier {
    let theme: Theme
    let store: HerdrBuildStore
    let pending: HerdrBuildStore.PendingConfirmation?

    func body(content: Content) -> some View {
        content.modifier(ConfirmCardPresenter(
            theme: theme,
            item: pending,
            content: { pending in
                ConfirmCardContent(
                    action: pending.confirmation.title, message: AttributedString(pending.confirmation.message),
                    confirmTitle: pending.confirmation.confirmButtonTitle, identifier: "flock.herdrMousePatch.banner"
                )
            },
            answer: { _, answer in
                if answer.confirmed {
                    store.confirmPendingAction()
                } else {
                    store.cancelPendingConfirmation()
                }
            }
        ))
    }
}

/// The tab area's bounds, which the top-bar overlay centres its card on.
/// Absent while the grid replaces the tab area.
struct TabAreaAnchor: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

/// The top-bar overlay and the window's other modal layers, one at a time:
/// opening it closes the rt modal, the palette and the switchers, and opening
/// any of those closes it.
private struct TopBarOverlayExclusion: ViewModifier {
    let viewModel: SessionViewModel

    @Environment(CommandPaletteState.self) private var commandPalette
    @Environment(WorkspaceSwitcher.self) private var switcher
    @Environment(TabSwitcher.self) private var tabSwitcher
    @Environment(AgentSwitcher.self) private var agentSwitcher
    @Environment(ProfileSwitcher.self) private var profileSwitcher: ProfileSwitcher?
    @Environment(ServerSwitcher.self) private var serverSwitcher: ServerSwitcher?

    func body(content: Content) -> some View {
        content
            .onChange(of: viewModel.topBarOverlay.openPin) { _, open in
                guard open != nil else { return }
                commandPalette.close()
                switcher.cancel()
                tabSwitcher.cancel()
                agentSwitcher.cancel()
                profileSwitcher?.cancel()
                serverSwitcher?.cancel()
                if viewModel.rt.modal != nil { Task { await viewModel.rt.closeModal() } }
            }
            .onChange(of: viewModel.rt.modal != nil) { _, shown in if shown { viewModel.topBarOverlay.close() } }
            .onChange(of: commandPalette.isOpen) { _, open in if open { viewModel.topBarOverlay.close() } }
            .onChange(
                of: switcher.isShown || tabSwitcher.isShown || agentSwitcher.isShown || profileSwitcher?.isShown == true || serverSwitcher?.isShown == true
            ) { _, shown in
                if shown { viewModel.topBarOverlay.close() }
            }
    }
}

struct TitleBar: View {
    let theme: Theme
    let sessionLabel: String
    let connectionState: ConnectionState
    let isDevBuild: Bool
    /// Overview's tab shows it while Overview is not the view shown.
    var blockedCount = 0
    /// Per tab, for renders.
    var forcedTabs: [ViewTab: ControlInteraction] = [:]
    /// Draws the top-bar workspaces; none without it.
    var viewModel: SessionViewModel? = nil
    /// The span that drags the window: the rail's width, so the tab strip
    /// beside it keeps its clicks. The whole bar when nil (renders, the grid).
    var leadingDragWidth: CGFloat? = nil
    /// How much of the bar's trailing end the cluster takes, so the tab strip
    /// stops short of it.
    var onTrailingWidth: ((CGFloat) -> Void)? = nil
    /// The chat sidebar's width: its header shares the bar's row, so the
    /// cluster ends where the sidebar starts.
    var trailingReserve: CGFloat = 0
    /// A machine profile's connection line, which replaces "herdr · label".
    var machineNotice: MachineNotice? = nil

    /// Present only in Flock Dev, which is the only flavor `FlockApp` hands one.
    @Environment(DevBuildWatcher.self) private var devBuild: DevBuildWatcher?
    @Environment(DevRebuild.self) private var devRebuild: DevRebuild?
    @Environment(HerdrBuildStore.self) private var herdrBuild: HerdrBuildStore?
    @Environment(SettingsTabSelection.self) private var settingsSelection: SettingsTabSelection?
    @Environment(\.openSettings) private var openSettings

    @State private var showsMachineNoticeDetail = false

    private var hasTopBarWorkspaces: Bool {
        viewModel?.railSections(board: nil)?.topBar.isEmpty == false
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Only the bar's empty span over the rail drags the window: the
            // workspace's tab strip shares this row, and it must keep its clicks.
            TitleBarMouseArea()
                .frame(width: leadingDragWidth ?? .infinity, height: ChromeMetrics.TitleBar.height)
            Rectangle()
                .fill(theme.hair)
                .frame(height: ChromeMetrics.ruleWidth)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .allowsHitTesting(false)
            // Over the rail, beside the window buttons: the bar's one empty
            // stretch, which keeps the trailing corner clear of the pane's own
            // controls below it.
            ViewTabBar(theme: theme, blockedCount: blockedCount, forced: forcedTabs, showsTitles: false)
                .frame(height: ChromeMetrics.TitleBar.height)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.leading, ChromeMetrics.TitleBar.tabsLeadingInset)
            trailingCluster
                .padding(.trailing, trailingReserve)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        }
        .frame(maxWidth: .infinity)
        .frame(height: ChromeMetrics.TitleBar.height)
    }

    private var hasNotices: Bool {
        devBuild?.newerBuildReady == true || (devRebuild.map { $0.state != .idle } ?? false) || noticeColor != nil || machineNotice != nil
            || herdrUpdate != nil
    }

    /// The build is this Mac's herdr, which a machine's panes do not run on.
    private var herdrUpdate: String? {
        viewModel?.isRemoteMachine == true ? nil : herdrBuild?.availableUpdate
    }

    /// One even gap between whichever of these show, so a missing one leaves
    /// no hole.
    private var trailingCluster: some View {
        HStack(spacing: ChromeMetrics.TitleBar.clusterGap) {
            if isDevBuild {
                DevStatusMenu(theme: theme)
            }
            if hasNotices {
                HStack(spacing: ChromeMetrics.TitleBar.noticeSpacing) {
                    if let devBuild, devBuild.newerBuildReady {
                        RestartForNewBuildButton(theme: theme, action: devBuild.relaunch)
                    } else if let devRebuild {
                        DevRebuildPill(theme: theme, state: devRebuild.state, openLog: devRebuild.openLog)
                    }
                    if let newest = herdrUpdate {
                        HerdrUpdatePill(theme: theme, newest: newest) {
                            settingsSelection?.tab = .herdr
                            openSettings()
                        }
                    }
                    connectionNotice
                }
                .fixedSize()
            }
            if let viewModel, hasTopBarWorkspaces {
                TopBarWorkspaceStrip(theme: theme, viewModel: viewModel, showsNames: false)
                    .fixedSize()
            }
        }
        // Every item centres on the bar's own height.
        .frame(height: ChromeMetrics.TitleBar.height)
        .padding(.trailing, ChromeMetrics.TitleBar.trailingInset)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { onTrailingWidth?($0) }
        .onChange(of: machineNotice?.text) { showsMachineNoticeDetail = false }
    }

    /// Only while the session is not live, so a connected window's bar carries
    /// nothing but its title.
    @ViewBuilder
    private var connectionNotice: some View {
        if let machineNotice {
            HStack(spacing: ChromeMetrics.TitleBar.noticeSpacing) {
                Circle()
                    .fill(ProfileConnectionDot.attention.color(in: theme))
                    .frame(width: ChromeMetrics.TitleBar.noticeDot, height: ChromeMetrics.TitleBar.noticeDot)
                Button { showsMachineNoticeDetail.toggle() } label: {
                    Text(MachineConnectionCopy.short(machineNotice.text))
                        .font(ChromeType.connectionNotice)
                        .foregroundStyle(theme.textLabel)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: ChromeMetrics.TitleBar.machineNoticeMaxWidth, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(machineNotice.text)
                .popover(isPresented: $showsMachineNoticeDetail, arrowEdge: .bottom) {
                    Text(machineNotice.text)
                        .font(ChromeType.connectionNotice)
                        .foregroundStyle(theme.textStrong)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: ChromeMetrics.TitleBar.machineNoticePopoverWidth, alignment: .leading)
                        .padding(ChromeMetrics.TitleBar.machineNoticePopoverPadding)
                        .background(theme.chrome)
                        .accessibilityIdentifier("flock.titleBar.machineNoticeDetail")
                }
                .accessibilityIdentifier("flock.titleBar.machineNotice")
                if let action = machineNotice.action {
                    Button(action.title, action: action.perform)
                        .buttonStyle(.plain)
                        .font(ChromeType.connectionNotice)
                        .foregroundStyle(theme.accent)
                        .accessibilityIdentifier("flock.titleBar.machineNoticeAction")
                }
            }
        } else if let color = noticeColor {
            HStack(spacing: ChromeMetrics.TitleBar.noticeSpacing) {
                Circle().fill(color).frame(width: ChromeMetrics.TitleBar.noticeDot, height: ChromeMetrics.TitleBar.noticeDot)
                Text("herdr · \(sessionLabel)")
                    .font(ChromeType.connectionNotice)
                    .foregroundStyle(theme.textLabel)
            }
        }
    }

    private var noticeColor: Color? {
        switch connectionState {
        case .live: nil
        case .connecting, .reconnecting, .notRunning: theme.yellow
        case .unsupported: theme.red
        }
    }
}

/// Flock Dev's mark beside the title, so a glance at the window says which
/// build it is.
struct DevTag: View {
    let theme: Theme
    /// What the tag is forcing, if anything (`DevStatusMenu`).
    var suffix: String? = nil

    var body: some View {
        Text(suffix.map { "DEV · \($0)" } ?? "DEV")
            .font(ChromeType.devTag)
            .tracking(ChromeType.devTagTracking)
            .foregroundStyle(theme.textLabel)
            .padding(.horizontal, ChromeMetrics.TitleBar.devTagHorizontalPadding)
            .padding(.vertical, ChromeMetrics.TitleBar.devTagVerticalPadding)
            .background(theme.lift, in: Capsule())
            .accessibilityIdentifier("flock.titleBar.devTag")
    }
}

private struct RestartForNewBuildButton: View {
    let theme: Theme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: ChromeMetrics.TitleBar.restartGlyphSpacing) {
                Image(systemName: "arrow.clockwise")
                    .font(ChromeType.restartGlyph)
                Text("New build · Restart")
                    .font(ChromeType.restartLabel)
            }
            .foregroundStyle(theme.chrome)
            .padding(.horizontal, ChromeMetrics.TitleBar.restartHorizontalPadding)
            .padding(.vertical, ChromeMetrics.TitleBar.restartVerticalPadding)
            .background(theme.yellow, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background(WindowDragExclusion())
        .help("Quit and reopen Flock Dev on the build that just landed")
        .accessibilityIdentifier("flock.titleBar.restartForNewBuild")
    }
}

/// The unprompted offer to install or update the mattstack build. An offer,
/// not a fault, so it carries the accent rather than the red the protocol
/// banner uses: nothing is broken here, there is simply something flock can do.
///
/// Install routes through the store's ordinary request, so the
/// replace-this-path confirmation still appears. This shortens the walk to
/// the settings row; it does not skip the step that names the binary about
/// to be replaced.
private struct HerdrBuildBanner: View {
    let theme: Theme
    let store: HerdrBuildStore

    private var isUpdate: Bool {
        if case .outdated = store.state { return true }
        return false
    }

    var body: some View {
        HStack(spacing: ChromeMetrics.Banner.spacing) {
            Image(systemName: isUpdate ? "arrow.up.circle" : "cursorarrow.click")
                .font(ChromeType.bannerSymbol)
                .foregroundStyle(theme.accent)
            if let message = store.bannerErrorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(ChromeType.banner)
                    .foregroundStyle(theme.red)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityIdentifier("flock.herdrMousePatch.banner.error")
            } else {
                Text(HerdrBuildOffer.bannerHeadline(for: store.state))
                    .font(ChromeType.banner)
                    .foregroundStyle(theme.textStrong)
                Text(HerdrBuildOffer.bannerDetail(for: store.state))
                    .font(ChromeType.banner)
                    .foregroundStyle(theme.textLabel)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: ChromeMetrics.Banner.spacing)
            trailing
        }
        .padding(.horizontal, ChromeMetrics.Banner.horizontalPadding)
        .padding(.vertical, ChromeMetrics.Banner.verticalPadding)
        .boundedBackground(theme.accent.opacity(0.12))
        .accessibilityIdentifier("flock.herdrMousePatch.banner")
    }

    @ViewBuilder
    private var trailing: some View {
        switch store.phase {
        case .downloading(let fraction):
            busy("Downloading...", fraction: fraction)
        case .installing:
            busy("Installing...", fraction: 1)
        case .idle:
            Button(HerdrBuildOffer.bannerDismissTitle) { store.dismissBannerOffer() }
                .buttonStyle(.plain)
                .font(ChromeType.banner)
                .foregroundStyle(theme.textLabel)
                .accessibilityIdentifier("flock.herdrMousePatch.banner.dismiss")
            if !store.serverRestarting, HerdrBuildOffer.hasAction(for: store.state) {
                BannerPillButton(theme: theme, title: HerdrBuildOffer.bannerActionTitle(for: store.state)) {
                    store.requestInstall(source: .banner)
                }
                .accessibilityIdentifier("flock.herdrMousePatch.banner.install")
            }
        }
    }

    /// Drawn rather than a `ProgressView`: AppKit paints a linear bar gray in
    /// a window that is not key, whatever its tint. The hidden pill holds the
    /// banner at the height it has with Install showing.
    private func busy(_ title: String, fraction: Double) -> some View {
        ZStack(alignment: .trailing) {
            BannerPillButton(theme: theme, title: HerdrBuildOffer.bannerActionTitle(for: store.state)) {}
                .hidden()
            HStack(spacing: ChromeMetrics.Banner.spacing) {
                Text(title)
                    .font(ChromeType.banner)
                    .foregroundStyle(theme.textLabel)
                Capsule()
                    .fill(theme.accent.opacity(0.25))
                    .frame(width: 96, height: 6)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(theme.accent)
                            .frame(width: 96 * min(max(fraction, 0), 1), height: 6)
                    }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text("\(Int(fraction * 100)) percent"))
        .accessibilityIdentifier("flock.herdrMousePatch.banner.progress")
    }
}

/// Restart herdr goes through the store's confirmation, which says the
/// panes keep running and that Flock restarts after.
private struct HerdrRestartBanner: View {
    let theme: Theme
    let store: HerdrBuildStore
    let reason: HerdrBuildCopy.RestartReason

    private var restartsServer: Bool { store.needsServerRestart }

    var body: some View {
        HStack(spacing: ChromeMetrics.Banner.spacing) {
            Image(systemName: "arrow.clockwise")
                .font(ChromeType.bannerSymbol)
                .foregroundStyle(theme.accent)
            if let message = store.serverRestartError {
                Label(HerdrBuildCopy.serverRestartFailedBanner, systemImage: "exclamationmark.triangle.fill")
                    .font(ChromeType.banner)
                    .foregroundStyle(theme.red)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(message)
                    .accessibilityIdentifier("flock.herdrMousePatch.restartBanner.error")
            } else {
                Text(HerdrBuildCopy.restartHeadline(for: reason))
                    .font(ChromeType.banner)
                    .foregroundStyle(theme.textStrong)
                    .lineLimit(1)
                    .fixedSize()
                Text(HerdrBuildCopy.restartDetail(for: reason, restartsServer: restartsServer))
                    .font(ChromeType.banner)
                    .foregroundStyle(theme.textLabel)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: ChromeMetrics.Banner.spacing)
            trailing
        }
        .padding(.horizontal, ChromeMetrics.Banner.horizontalPadding)
        .padding(.vertical, ChromeMetrics.Banner.verticalPadding)
        .boundedBackground(theme.accent.opacity(0.12))
        .accessibilityIdentifier("flock.herdrMousePatch.restartBanner")
    }

    @ViewBuilder
    private var trailing: some View {
        let title = HerdrBuildCopy.restartActionTitle(restartsServer: restartsServer)
        if store.serverRestarting {
            ZStack(alignment: .trailing) {
                BannerPillButton(theme: theme, title: title) {}
                    .hidden()
                Text(HerdrBuildCopy.serverRestartProgressTitle)
                    .font(ChromeType.banner)
                    .foregroundStyle(theme.textLabel)
            }
            .accessibilityIdentifier("flock.herdrMousePatch.banner.restarting")
        } else {
            if reason == .serverBehind {
                Button(HerdrBuildOffer.bannerDismissTitle) { store.dismissServerBehindBanner() }
                    .buttonStyle(.plain)
                    .font(ChromeType.banner)
                    .foregroundStyle(theme.textLabel)
                    .accessibilityIdentifier("flock.herdrMousePatch.restartBanner.dismiss")
            }
            BannerPillButton(theme: theme, title: title) {
                if restartsServer {
                    store.requestServerRestart(source: .banner)
                } else {
                    AppRelaunch.relaunch()
                }
            }
            .accessibilityIdentifier("flock.herdrMousePatch.banner.restart")
        }
    }
}

private struct BannerPillButton: View {
    let theme: Theme
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(ChromeType.bannerAction)
                .foregroundStyle(theme.chrome)
                .padding(.horizontal, ChromeMetrics.TitleBar.restartHorizontalPadding)
                .padding(.vertical, ChromeMetrics.TitleBar.restartVerticalPadding)
                .background(theme.accent, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct UnsupportedBanner: View {
    let theme: Theme
    let mismatch: ProtocolMismatch

    var body: some View {
        HStack(spacing: ChromeMetrics.Banner.spacing) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(ChromeType.bannerSymbol)
                .foregroundStyle(theme.red)
            Text(
                "herdr is too old for flock (found protocol \(mismatch.found), "
                    + "need \(mismatch.required)). Run `herdr update`."
            )
            .font(ChromeType.banner)
            .foregroundStyle(theme.textStrong)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, ChromeMetrics.Banner.horizontalPadding)
        .padding(.vertical, ChromeMetrics.Banner.verticalPadding)
        .boundedBackground(theme.red.opacity(0.12))
    }
}
