import AppKit
import PaddockCore
import SwiftUI

/// The whole window: title bar, workspace rail, tab strip, pane canvas.
/// Every color comes from the active theme's roles via the environment.
struct MainWindow: View {
    @Environment(ThemeStore.self) private var themeStore
    @Environment(DragCoordinator.self) private var dragCoordinator
    let viewModel: SessionViewModel
    let sessionLabel: String

    private var theme: Theme { themeStore.active }

    var body: some View {
        VStack(spacing: 0) {
            TitleBar(theme: theme, sessionLabel: sessionLabel, connectionState: viewModel.connectionState)
            if let banner = viewModel.unsupportedBanner {
                UnsupportedBanner(theme: theme, mismatch: banner)
            }
            HStack(spacing: 0) {
                WorkspaceRail(
                    theme: theme,
                    viewModel: viewModel,
                    onSelect: { id in Task { await viewModel.jumpToHerdr(workspace: id) } }
                )
                VStack(spacing: 0) {
                    TabStrip(
                        theme: theme,
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
        .background(theme.chrome)
        // Names the one space every drag frame and drag point is expressed in
        // -- see `DragSpace`. Applied before the overlays so they resolve it
        // too, and so a rail/strip/canvas frame and a ghost position are
        // directly comparable.
        .coordinateSpace(.named(DragSpace.name))
        // Laid out at the named space's own frame, which is what lets a raw
        // AppKit event location be converted into it.
        .background(DragSpaceAnchor(coordinator: dragCoordinator))
        .overlay { DragLayer() }
        .overlay { ToastHost() }
        .frame(minWidth: 900, minHeight: 560)
        .ignoresSafeArea(edges: .top)
        .background(TitlebarConfigurator(windowBg: theme.chrome))
    }
}

private struct TitleBar: View {
    let theme: Theme
    let sessionLabel: String
    let connectionState: ConnectionState

    var body: some View {
        Text("paddock")
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(theme.textStrong)
            .frame(maxWidth: .infinity)
            .frame(height: ChromeMetrics.titleBarHeight)
            .overlay(alignment: .trailing) { connectionNotice }
            .background(theme.chrome)
    }

    /// Only while the session is not live, so a connected window's bar carries
    /// nothing but its title.
    @ViewBuilder
    private var connectionNotice: some View {
        if let color = noticeColor {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 5, height: 5)
                Text("herdr · \(sessionLabel)")
                    .font(.system(size: 9))
                    .foregroundStyle(theme.textLabel)
            }
            .padding(.trailing, 10)
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
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(theme.red)
            Text(
                "herdr is too old for paddock (found protocol \(mismatch.found), "
                    + "need \(mismatch.required)). Run `herdr update`."
            )
            .font(.system(size: 11))
            .foregroundStyle(theme.textStrong)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(theme.red.opacity(0.12))
    }
}
