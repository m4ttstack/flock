import AppKit
import FlockCore
import SwiftUI

/// The whole window: title bar, workspace rail, tab strip, pane canvas.
/// Every color comes from the active theme's roles via the environment.
struct MainWindow: View {
    @Environment(ThemeStore.self) private var themeStore
    @Environment(DragCoordinator.self) private var dragCoordinator
    @Environment(RailWidthStore.self) private var railWidth
    let viewModel: SessionViewModel
    let sessionLabel: String

    private var theme: Theme { themeStore.active }

    var body: some View {
        VStack(spacing: 0) {
            TitleBar(theme: theme, sessionLabel: sessionLabel, connectionState: viewModel.connectionState)
            if let banner = viewModel.unsupportedBanner {
                UnsupportedBanner(theme: theme, mismatch: banner)
            }
            if dragCoordinator.isGridShown {
                AllWorkspacesGrid(theme: theme, viewModel: viewModel)
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
                }
            }
        }
        .background(theme.chrome)
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
        .overlay { ToastHost(viewModel: viewModel) }
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
            Button("Close Group", role: .destructive) {
                Task { await viewModel.confirmGroupClose(pending.workspaceID) }
            }
            .accessibilityIdentifier("flock.workspace.closeGroup.confirm")
            Button("Cancel", role: .cancel) { viewModel.cancelPendingGroupClose() }
                .accessibilityIdentifier("flock.workspace.closeGroup.cancel")
        } message: { pending in
            Text(
                "herdr keeps \"\(pending.label)\" and its linked worktree workspaces together. "
                    + "Closing it closes all of them."
            )
        }
    }
}

private struct TitleBar: View {
    let theme: Theme
    let sessionLabel: String
    let connectionState: ConnectionState

    var body: some View {
        Text("flock")
            .font(ChromeType.windowTitle)
            .foregroundStyle(theme.textStrong)
            .padding(.top, ChromeMetrics.TitleBar.titleTopInset)
            .frame(maxWidth: .infinity)
            .frame(height: ChromeMetrics.TitleBar.height)
            .overlay(alignment: .trailing) { connectionNotice }
            .overlay { TitleBarMouseArea() }
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
            .padding(.trailing, ChromeMetrics.TitleBar.noticeTrailingPadding)
        }
    }

    private var noticeColor: Color? {
        switch connectionState {
        case .live: nil
        case .connecting, .reconnecting: theme.yellow
        case .unsupported: theme.red
        }
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
