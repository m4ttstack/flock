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
    @Environment(AllWorkspacesModeStore.self) private var allWorkspacesMode
    let viewModel: SessionViewModel
    let sessionLabel: String
    let herdrMousePatchStore: HerdrMousePatchStore
    var isDevBuild = BuildFlavor.isDev

    private var theme: Theme { themeStore.active }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: ChromeMetrics.TitleBar.height)
            if let banner = viewModel.unsupportedBanner {
                UnsupportedBanner(theme: theme, mismatch: banner)
            }
            // Below the protocol banner deliberately: a herdr too old to talk
            // to at all outranks an optional capability of one that works.
            if let reason = herdrMousePatchStore.restartReason {
                HerdrMousePatchRestartBanner(theme: theme, reason: reason)
            } else if herdrMousePatchStore.shouldOfferBanner {
                HerdrMousePatchBanner(theme: theme, store: herdrMousePatchStore)
            }
            if dragCoordinator.isGridShown {
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
                        onSelect: { id in Task { await viewModel.jumpToHerdr(workspace: id) } }
                    )
                    VStack(spacing: 0) {
                        TabStrip(
                            theme: theme,
                            viewModel: viewModel,
                            workspace: viewModel.selectedWorkspaceID,
                            tabs: viewModel.tabsForSelectedWorkspace,
                            selectedTabID: viewModel.selectedTabID,
                            herdrVersion: viewModel.model?.herdrVersion,
                            onSelect: { id in Task { await viewModel.jumpToHerdr(tab: id) } }
                        )
                        PaneCanvas(theme: theme, viewModel: viewModel, layout: viewModel.selectedLayout)
                    }
                    // On the tab area alone, so the rail stays clear and
                    // undimmed. The grid mounts its own over a focused pane.
                    .overlay { RtModalView(theme: theme, viewModel: viewModel) }
                    .overlay { CommandPaletteView(theme: theme, viewModel: viewModel) }
                    .overlay { SwitcherOverlay(theme: theme, viewModel: viewModel) }
                }
            }
        }
        .background(theme.chrome)
        // Below the title bar and over everything else, rail included, so it
        // opens from any view and its icon can close it again.
        .overlay {
            TopBarWorkspaceOverlay(theme: theme, viewModel: viewModel)
                .padding(.top, ChromeMetrics.TitleBar.height)
        }
        // Over the content rather than above it in the stack: the tab strip's
        // `NSScrollView` stretches up through the system title bar's safe
        // area to the window's top edge. Stacked, that scroll view sits over
        // the bar and takes its clicks.
        .overlay(alignment: .top) {
            TitleBar(
                theme: theme, sessionLabel: sessionLabel, connectionState: viewModel.connectionState,
                isDevBuild: isDevBuild, needsYouCount: viewModel.attentionToasts.toasts.count, viewModel: viewModel
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
        // Here, where both always render: the grid replaces the tab area the
        // palette draws over, and a rename editor on the live rail needs the
        // Return and Esc the palette would take.
        .onChange(of: dragCoordinator.isGridShown) { _, shown in
            if shown { commandPalette.close(); switcher.cancel(); tabSwitcher.cancel() }
        }
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
            if renaming { commandPalette.close(); switcher.cancel(); tabSwitcher.cancel() }
        }
        .onChange(of: viewModel.selectedWorkspaceID, initial: true) { _, id in
            if let id { switcher.note(id) }
        }
        .onChange(of: viewModel.selectedTabID, initial: true) { _, id in
            if let id { tabSwitcher.note(id) }
        }
        .frame(minWidth: 900, minHeight: 560)
        .ignoresSafeArea(edges: .top)
        .background(TitlebarConfigurator(windowBg: theme.chrome))
        // herdr refuses a plain close on a workspace that is a worktree
        // group's primary; this is that refusal, asked rather than reported.
        //
        // `presenting:` is what makes the confirm correct, not just tidier:
        // the dialog clears its own presentation state as it dismisses, which
        // runs before the button's enqueued work does, so an action that read
        // the workspace back off `pendingGroupClose` would find it already
        // nil. The presented value is captured when the prompt goes up, and
        // it is also what lets the message name what is about to close.
        .confirmationDialog(
            "Close this workspace and its worktrees?",
            isPresented: Binding(
                get: { viewModel.pendingGroupClose != nil },
                set: { shown in if !shown { viewModel.cancelPendingGroupClose() } }
            ),
            titleVisibility: .visible,
            presenting: viewModel.pendingGroupClose
        ) { pending in
            Button("Close Group") {
                Task { await viewModel.confirmGroupClose(pending.workspaceID) }
            }
            // No destructive role: as the default it draws blue anyway, and the
            // role's red flashes back in as the prompt dismisses.
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("flock.workspace.closeGroup.confirm")
            Button("Cancel", role: .cancel) { viewModel.cancelPendingGroupClose() }
                .accessibilityIdentifier("flock.workspace.closeGroup.cancel")
        } message: { pending in
            // The busy sentence is absent when nothing is, so a quiet
            // workspace reads exactly as it did before.
            Text(
                ([
                    "herdr keeps \"\(pending.label)\" and its linked worktree workspaces together. "
                        + "Closing it closes all of them.",
                    pending.busy.groupSentence,
                ] as [String?]).compactMap { $0 }.joined(separator: " ")
            )
        }
        // A pane or tab close herdr would escalate into a tab or a workspace.
        // One prompt for both verbs, since one rule decides both. Same
        // `presenting:` shape, and for the same reason: what the confirm button
        // closes is captured when the prompt goes up.
        .confirmationDialog(
            viewModel.pendingClose?.title ?? "",
            isPresented: Binding(
                get: { viewModel.pendingClose != nil },
                set: { shown in if !shown { viewModel.cancelPendingClose() } }
            ),
            titleVisibility: .visible,
            presenting: viewModel.pendingClose
        ) { pending in
            Button(pending.confirmButtonTitle) {
                Task { await viewModel.confirmClose(pending.subject) }
            }
            // No destructive role: as the default it draws blue anyway, and the
            // role's red flashes back in as the prompt dismisses.
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("flock.close.confirm")
            Button("Cancel", role: .cancel) { viewModel.cancelPendingClose() }
                .accessibilityIdentifier("flock.close.cancel")
        } message: { pending in
            Text(pending.message)
        }
        .modifier(TopBarRefusalAlert(viewModel: viewModel))
        // The same confirmation the settings row raises, hosted here too so
        // the banner's Install is the identical action rather than a shortcut
        // around it. Naming the exact path being replaced is the point of it,
        // and it is shown every time by design.
        .confirmationDialog(
            herdrMousePatchStore.pendingConfirmation?.confirmation.title ?? "",
            isPresented: Binding(
                get: { herdrMousePatchStore.pendingConfirmation != nil },
                set: { shown in if !shown { herdrMousePatchStore.cancelPendingConfirmation() } }
            ),
            titleVisibility: .visible,
            presenting: herdrMousePatchStore.pendingConfirmation
        ) { pending in
            Button(pending.confirmation.confirmButtonTitle) { herdrMousePatchStore.confirmPendingAction() }
                .accessibilityIdentifier("flock.herdrMousePatch.banner.confirm")
            Button("Cancel", role: .cancel) { herdrMousePatchStore.cancelPendingConfirmation() }
        } message: { pending in
            Text(pending.confirmation.message)
        }
    }
}

private struct TopBarRefusalAlert: ViewModifier {
    let viewModel: SessionViewModel

    func body(content: Content) -> some View {
        content.alert(
            viewModel.topBarRefusal?.title ?? "",
            isPresented: Binding(
                get: { viewModel.topBarRefusal != nil },
                set: { shown in if !shown { viewModel.dismissTopBarRefusal() } }
            ),
            presenting: viewModel.topBarRefusal
        ) { _ in
            Button("OK") { viewModel.dismissTopBarRefusal() }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("flock.topBar.refusal.ok")
        } message: { refusal in
            Text(refusal.message)
        }
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

    func body(content: Content) -> some View {
        content
            .onChange(of: viewModel.topBarOverlay.openPin) { _, open in
                guard open != nil else { return }
                commandPalette.close()
                switcher.cancel()
                tabSwitcher.cancel()
                if viewModel.rt.modal != nil { Task { await viewModel.rt.closeModal() } }
            }
            .onChange(of: viewModel.rt.modal != nil) { _, shown in if shown { viewModel.topBarOverlay.close() } }
            .onChange(of: commandPalette.isOpen) { _, open in if open { viewModel.topBarOverlay.close() } }
            .onChange(of: switcher.isShown || tabSwitcher.isShown) { _, shown in
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
    var needsYouCount = 0
    /// Per tab, for renders.
    var forcedTabs: [ViewTab: ControlInteraction] = [:]
    /// Draws the top-bar workspaces; none without it.
    var viewModel: SessionViewModel? = nil

    /// Present only in Flock Dev, which is the only flavor `FlockApp` hands one.
    @Environment(DevBuildWatcher.self) private var devBuild: DevBuildWatcher?
    @Environment(TopBarLabelStore.self) private var labels: TopBarLabelStore?

    @State private var barWidth: CGFloat = 0
    @State private var titleWidth: CGFloat = 0
    @State private var tabsMaxX: CGFloat = 0
    @State private var trailingWidth: CGFloat = 0
    @State private var noticesWidth: CGFloat = 0
    @State private var namedStripWidth: CGFloat = 0

    private var showsTitle: Bool {
        TitleBarFit.showsTitle(
            barWidth: barWidth, titleWidth: titleWidth, leadingEdge: tabsMaxX, trailingWidth: trailingWidth,
            gap: ChromeMetrics.TitleBar.titleClearance
        )
    }

    private var showsNames: Bool {
        labels?.label == .iconAndName && TitleBarFit.showsNames(
            barWidth: barWidth, leadingEdge: tabsMaxX, noticesWidth: noticesWidth,
            namedStripWidth: namedStripWidth, gap: ChromeMetrics.TitleBar.titleClearance
        )
    }

    private var hasTopBarWorkspaces: Bool {
        viewModel?.railSections(board: nil)?.topBar.isEmpty == false
    }

    private var hasNotices: Bool {
        devBuild?.newerBuildReady == true || noticeColor != nil
    }

    var body: some View {
        HStack(spacing: ChromeMetrics.TitleBar.devTagSpacing) {
            Text("flock")
                .font(ChromeType.windowTitle)
                .foregroundStyle(theme.textStrong)
            if isDevBuild {
                DevTag(theme: theme)
            }
        }
        .fixedSize()
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { titleWidth = $0 }
        // Hidden rather than removed, so its width is still measured.
        .opacity(showsTitle ? 1 : 0)
        .accessibilityHidden(!showsTitle)
        .padding(.top, ChromeMetrics.TitleBar.titleTopInset)
        .frame(maxWidth: .infinity)
        .frame(height: ChromeMetrics.TitleBar.height)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { barWidth = $0 }
        .overlay { TitleBarMouseArea() }
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.rule).frame(height: ChromeMetrics.ruleWidth).allowsHitTesting(false)
        }
        // Over the mouse area, which would otherwise take the tabs' and the
        // restart pill's clicks for a title-bar drag.
        .overlay(alignment: .bottomLeading) {
            ViewTabBar(theme: theme, needsYouCount: needsYouCount, forced: forcedTabs)
                .frame(height: ChromeMetrics.TitleBar.height)
                .padding(.leading, ChromeMetrics.TitleBar.tabsLeadingInset)
                .fixedSize(horizontal: true, vertical: false)
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .local).width } action: {
                    tabsMaxX = $0
                }
        }
        .overlay(alignment: .trailing) {
            HStack(spacing: 0) {
                if let viewModel, hasTopBarWorkspaces {
                    TopBarWorkspaceStrip(theme: theme, viewModel: viewModel, showsNames: showsNames)
                        .frame(height: ChromeMetrics.TitleBar.height)
                        .fixedSize()
                        // Measured named whatever is drawn, so the fit rule
                        // reads the width names would need.
                        .background {
                            TopBarWorkspaceStrip(theme: theme, viewModel: viewModel, showsNames: true, measuring: true)
                                .fixedSize()
                                .hidden()
                                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { namedStripWidth = $0 }
                        }
                }
                HStack(spacing: ChromeMetrics.TitleBar.noticeSpacing) {
                    if let devBuild, devBuild.newerBuildReady {
                        RestartForNewBuildButton(theme: theme, action: devBuild.relaunch)
                    }
                    connectionNotice
                }
                // Cells sit flush with the bar's edge when no notice follows them.
                .padding(.leading, hasTopBarWorkspaces && hasNotices ? ChromeMetrics.TitleBar.noticeTrailingPadding : 0)
                .padding(.trailing, hasTopBarWorkspaces && !hasNotices ? 0 : ChromeMetrics.TitleBar.noticeTrailingPadding)
                .fixedSize()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { noticesWidth = $0 }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { trailingWidth = $0 }
        }
        .background(theme.chrome)
    }

    /// Only while the session is not live, so a connected window's bar carries
    /// nothing but its title.
    @ViewBuilder
    private var connectionNotice: some View {
        if let color = noticeColor {
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

/// Flock Dev's mark beside the title, in the same amber as the band on its
/// icon, so a glance at the window says which build it is.
private struct DevTag: View {
    let theme: Theme

    var body: some View {
        Text("DEV")
            .font(ChromeType.devTag)
            .tracking(ChromeType.devTagTracking)
            .foregroundStyle(theme.chrome)
            .padding(.horizontal, ChromeMetrics.TitleBar.devTagHorizontalPadding)
            .padding(.vertical, ChromeMetrics.TitleBar.devTagVerticalPadding)
            .background(theme.yellow, in: Capsule())
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

/// The unprompted offer to patch herdr for mouse events. An offer, not a
/// fault, so it carries the accent rather than the red the protocol banner
/// uses: nothing is broken here, there is simply something flock can do.
///
/// Install routes through the store's ordinary request, so the
/// replace-this-path confirmation still appears. This shortens the walk to
/// the settings row; it does not skip the step that names the binary about
/// to be replaced.
private struct HerdrMousePatchBanner: View {
    let theme: Theme
    let store: HerdrMousePatchStore

    var body: some View {
        HStack(spacing: ChromeMetrics.Banner.spacing) {
            Image(systemName: "cursorarrow.click")
                .font(ChromeType.bannerSymbol)
                .foregroundStyle(theme.accent)
            Text(HerdrMousePatchOffer.bannerHeadline)
                .font(ChromeType.banner)
                .foregroundStyle(theme.textStrong)
            Text(HerdrMousePatchOffer.bannerDetail)
                .font(ChromeType.banner)
                .foregroundStyle(theme.textLabel)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: ChromeMetrics.Banner.spacing)
            Button(HerdrMousePatchOffer.bannerDismissTitle) { store.dismissBannerOffer() }
                .buttonStyle(.plain)
                .font(ChromeType.banner)
                .foregroundStyle(theme.textLabel)
                .accessibilityIdentifier("flock.herdrMousePatch.banner.dismiss")
            BannerPillButton(theme: theme, title: HerdrMousePatchOffer.bannerActionTitle) { store.requestInstall() }
                .accessibilityIdentifier("flock.herdrMousePatch.banner.install")
        }
        .padding(.horizontal, ChromeMetrics.Banner.horizontalPadding)
        .padding(.vertical, ChromeMetrics.Banner.verticalPadding)
        .boundedBackground(theme.accent.opacity(0.12))
        .accessibilityIdentifier("flock.herdrMousePatch.banner")
    }
}

private struct HerdrMousePatchRestartBanner: View {
    let theme: Theme
    let reason: HerdrMousePatchCopy.RestartReason

    var body: some View {
        HStack(spacing: ChromeMetrics.Banner.spacing) {
            Image(systemName: "arrow.clockwise")
                .font(ChromeType.bannerSymbol)
                .foregroundStyle(theme.accent)
            Text(HerdrMousePatchCopy.restartHeadline(for: reason))
                .font(ChromeType.banner)
                .foregroundStyle(theme.textStrong)
            Text(HerdrMousePatchCopy.restartDetail)
                .font(ChromeType.banner)
                .foregroundStyle(theme.textLabel)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: ChromeMetrics.Banner.spacing)
            BannerPillButton(theme: theme, title: HerdrMousePatchCopy.restartActionTitle) { AppRelaunch.relaunch() }
                .accessibilityIdentifier("flock.herdrMousePatch.banner.restart")
        }
        .padding(.horizontal, ChromeMetrics.Banner.horizontalPadding)
        .padding(.vertical, ChromeMetrics.Banner.verticalPadding)
        .boundedBackground(theme.accent.opacity(0.12))
        .accessibilityIdentifier("flock.herdrMousePatch.restartBanner")
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
