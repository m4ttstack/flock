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
            if herdrMousePatchStore.shouldOfferBanner {
                HerdrMousePatchBanner(theme: theme, store: herdrMousePatchStore)
            }
            if dragCoordinator.isGridShown {
                AllWorkspacesGrid(theme: theme, viewModel: viewModel)
                    // The grid covers the rail and its dock, so the dock
                    // floats where the rail would be: the one layout with no
                    // rail to hold it.
                    .overlay(alignment: .bottomLeading) {
                        MessageDock(theme: theme, viewModel: viewModel, placement: .overGrid)
                            .frame(width: railWidth.width)
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
                            protocolVersion: HerdrClient.minimumProtocol,
                            onSelect: { id in Task { await viewModel.jumpToHerdr(tab: id) } }
                        )
                        PaneCanvas(theme: theme, viewModel: viewModel, layout: viewModel.selectedLayout)
                    }
                    // On the tab area alone, so the rail stays clear and
                    // undimmed. The grid needs none: the modal opens from a
                    // pane's rt button, which the grid does not show.
                    .overlay { RtModalView(theme: theme, viewModel: viewModel) }
                    .overlay { CommandPaletteView(theme: theme, viewModel: viewModel) }
                    .overlay { WorkspaceSwitcherView(theme: theme, viewModel: viewModel) }
                }
            }
        }
        .background(theme.chrome)
        // Over the content rather than above it in the stack: the system title
        // bar's safe area is taller than this bar, and the tab strip's
        // `NSScrollView` stretches up to the window's top edge through it.
        // Stacked, that scroll view sits over the bar and takes its clicks.
        .overlay(alignment: .top) {
            TitleBar(
                theme: theme, sessionLabel: sessionLabel, connectionState: viewModel.connectionState,
                isDevBuild: isDevBuild
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
            if shown { commandPalette.close(); switcher.cancel() }
        }
        .onChange(of: viewModel.renameEditorIsOnScreen) { _, renaming in
            if renaming { commandPalette.close(); switcher.cancel() }
        }
        .onChange(of: viewModel.selectedWorkspaceID, initial: true) { _, id in
            if let id { switcher.note(id) }
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

private struct TitleBar: View {
    let theme: Theme
    let sessionLabel: String
    let connectionState: ConnectionState
    let isDevBuild: Bool

    /// Present only in Flock Dev, which is the only flavor `FlockApp` hands one.
    @Environment(DevBuildWatcher.self) private var devBuild: DevBuildWatcher?

    var body: some View {
        HStack(spacing: ChromeMetrics.TitleBar.devTagSpacing) {
            Text("flock")
                .font(ChromeType.windowTitle)
                .foregroundStyle(theme.textStrong)
            if isDevBuild {
                DevTag(theme: theme)
            }
        }
        .padding(.top, ChromeMetrics.TitleBar.titleTopInset)
        .frame(maxWidth: .infinity)
        .frame(height: ChromeMetrics.TitleBar.height)
        .overlay { TitleBarMouseArea() }
        // Over the mouse area, which would otherwise take the restart click
        // for a title-bar drag.
        .overlay(alignment: .trailing) {
            HStack(spacing: ChromeMetrics.TitleBar.noticeSpacing) {
                if let devBuild, devBuild.newerBuildReady {
                    RestartForNewBuildButton(theme: theme, action: devBuild.relaunch)
                }
                connectionNotice
            }
            .padding(.trailing, ChromeMetrics.TitleBar.noticeTrailingPadding)
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
            Button(HerdrMousePatchOffer.bannerActionTitle) { store.requestInstall() }
                .accessibilityIdentifier("flock.herdrMousePatch.banner.install")
        }
        .padding(.horizontal, ChromeMetrics.Banner.horizontalPadding)
        .padding(.vertical, ChromeMetrics.Banner.verticalPadding)
        .boundedBackground(theme.accent.opacity(0.12))
        .accessibilityIdentifier("flock.herdrMousePatch.banner")
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
