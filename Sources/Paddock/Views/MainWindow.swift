import AppKit
import PaddockCore
import SwiftUI

/// The whole window: titlebar, workspace rail, tab strip, pane canvas.
/// Every color comes from the active theme via the environment; nothing here
/// hardcodes a chrome hex.
struct MainWindow: View {
    @Environment(ThemeStore.self) private var themeStore
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
        .background(theme.windowBg)
        // Names the one space every drag frame and drag point is expressed in
        // -- see `DragSpace`. Applied before the overlays so they resolve it
        // too, and so a rail/strip/canvas frame and a ghost position are
        // directly comparable.
        .coordinateSpace(.named(DragSpace.name))
        .overlay { DragLayer() }
        .overlay { ToastHost() }
        .frame(minWidth: 900, minHeight: 560)
        .ignoresSafeArea(edges: .top)
        .background(TitlebarConfigurator(windowBg: theme.windowBg))
    }
}

private struct TitleBar: View {
    let theme: Theme
    let sessionLabel: String
    let connectionState: ConnectionState

    var body: some View {
        HStack(spacing: 6) {
            // Reserves the space macOS draws the traffic lights into.
            Spacer().frame(width: 78)
            Text("paddock")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.text)
                .frame(maxWidth: .infinity)
            HStack(spacing: 6) {
                Circle().fill(connectionColor).frame(width: 7, height: 7)
                Text("herdr · \(sessionLabel)")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.subtext0)
            }
            .padding(.trailing, 16)
        }
        .frame(height: 44)
        .background(theme.windowBg)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.separator).frame(height: 1)
        }
    }

    private var connectionColor: Color {
        switch connectionState {
        case .live: theme.green
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
            .font(.system(size: 12))
            .foregroundStyle(theme.text)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.red.opacity(0.12))
    }
}

/// Merges the system titlebar into our own content so the traffic lights
/// sit directly on `TitleBar`'s dark 44px bar with zero gray system strip
/// above it: `.windowStyle(.hiddenTitleBar)` alone still leaves a titlebar
/// safe-area inset that pushes SwiftUI content down, so `MainWindow` also
/// ignores the top safe area, and this configurator paints the window's own
/// background so nothing shows through before the first frame draws.
private struct TitlebarConfigurator: NSViewRepresentable {
    let windowBg: Color

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { configure(view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: NSView) {
        guard let window = view.window else { return }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.backgroundColor = NSColor(windowBg)
    }
}
