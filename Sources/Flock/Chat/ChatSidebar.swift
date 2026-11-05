import AppKit
import FlockCore
import SwiftUI
import WebKit

/// The right sidebar: Flock's own header over the chat app's embed page.
struct ChatSidebar: View {
    let theme: Theme
    let store: ChatSidebarStore

    var body: some View {
        if let selection = store.selection, selection.isLinked(toTab: store.tabPanes) {
            HStack(spacing: 0) {
                Rectangle().fill(theme.rule).frame(width: ChromeMetrics.ruleWidth)
                if store.isCollapsed {
                    collapsedRail(selection)
                } else {
                    expanded(selection)
                }
            }
            .background(theme.chrome)
        }
    }

    private func expanded(_ selection: ChatSidebarSelection) -> some View {
        VStack(spacing: 0) {
            ChatSidebarHeader(theme: theme, store: store, selection: selection)
            Rectangle().fill(theme.rule).frame(height: ChromeMetrics.ruleWidth)
            if let url = store.embedURL {
                ChatEmbedWebView(
                    url: ChatEmbedAddress.themed(url, isDark: !ChromeRoles.isLight(panelBg: theme.palette.panelBg)),
                    onFailure: store.embedFailed
                )
            } else if store.chatAppIsDown {
                unreachable
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(width: ChromeMetrics.ChatSidebar.width)
    }

    private var unreachable: some View {
        VStack(spacing: ChromeMetrics.ChatSidebar.unreachableGap) {
            Text("Chat app isn't running")
                .font(ChromeType.chatComposeFieldText)
                .foregroundStyle(theme.overlay0)
            Button("Try again") { Task { await store.retry() } }
                .buttonStyle(.plain)
                .font(ChromeType.chatComposeFieldText)
                .foregroundStyle(theme.accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func collapsedRail(_ selection: ChatSidebarSelection) -> some View {
        Button(action: store.toggleCollapsed) {
            VStack(spacing: ChromeMetrics.ChatSidebar.railGap) {
                Image(systemName: "sidebar.right")
                    .font(.system(size: ChromeMetrics.ChatSidebar.iconSize))
                    .foregroundStyle(theme.overlay0)
                Circle()
                    .fill(selection.isEnded ? theme.overlay0 : theme.green)
                    .frame(width: ChromeMetrics.ChatSidebar.dotSize, height: ChromeMetrics.ChatSidebar.dotSize)
                Spacer(minLength: 0)
            }
            .padding(.top, ChromeMetrics.ChatSidebar.railTopPadding)
            .frame(width: ChromeMetrics.ChatSidebar.railWidth)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show the Slack chat with \(selection.chat.shownName)")
        .accessibilityIdentifier("flock.chatSidebar.expand")
    }
}

private struct ChatSidebarHeader: View {
    let theme: Theme
    let store: ChatSidebarStore
    let selection: ChatSidebarSelection

    @Environment(ChatStore.self) private var chatStore

    private var pane: PaneID? {
        selection.chat.pane.map { PaneID(rawValue: $0) }
    }

    private var isClosing: Bool {
        guard let pane else { return false }
        return chatStore.slackTransition(for: pane) == .closing
    }

    private var subtitle: String? {
        if selection.isEnded { return "Chat ended" }
        guard let pane else { return nil }
        let repo = chatStore.slackRepoName(ofAgent: pane.rawValue) ?? chatStore.buddies[pane]?.repo
        return repo.map { "Reads \($0)" }
    }

    var body: some View {
        HStack(spacing: ChromeMetrics.ChatSidebar.headerGap) {
            Circle()
                .fill(selection.isEnded ? theme.overlay0 : theme.green)
                .frame(width: ChromeMetrics.ChatSidebar.dotSize, height: ChromeMetrics.ChatSidebar.dotSize)
            VStack(alignment: .leading, spacing: ChromeMetrics.ChatSidebar.nameGap) {
                Text(selection.chat.shownName)
                    .font(ChromeType.chatComposeFieldText)
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(ChromeType.chatComposeFooterHint)
                        .foregroundStyle(theme.overlay0)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if !selection.isEnded, let pane {
                endButton(pane)
            }
            Button {
                if selection.isEnded { store.close() } else { store.toggleCollapsed() }
            } label: {
                Image(systemName: selection.isEnded ? "xmark" : "sidebar.right")
                    .font(.system(size: ChromeMetrics.ChatSidebar.iconSize))
                    .foregroundStyle(theme.overlay0)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(selection.isEnded ? "Close" : "Hide the chat")
            .accessibilityIdentifier("flock.chatSidebar.collapse")
        }
        .padding(.horizontal, ChromeMetrics.ChatSidebar.headerHorizontalPadding)
        .frame(height: ChromeMetrics.ChatSidebar.headerHeight)
        .task(id: selection.chat.room) { await chatStore.refreshBuddies() }
    }

    private func endButton(_ pane: PaneID) -> some View {
        Button {
            Task { await chatStore.endSlackChat(pane) }
        } label: {
            Text(isClosing ? "Closing…" : "End chat")
                .font(ChromeType.chatComposeFooterHint)
                .foregroundStyle(isClosing ? theme.overlay0 : theme.red)
                .padding(.horizontal, ChromeMetrics.ChatSidebar.endHorizontalPadding)
                .padding(.vertical, ChromeMetrics.ChatSidebar.endVerticalPadding)
                .background(
                    RoundedRectangle(cornerRadius: ChromeRadius.tiny).fill(Color(theme.palette.surface0))
                )
        }
        .buttonStyle(.plain)
        .disabled(isClosing)
        .accessibilityIdentifier("flock.chatSidebar.end")
    }
}

/// Keeps the sidebar's store reading rt for as long as the window is up,
/// whichever view it is drawing.
struct ChatSidebarFollower: ViewModifier {
    let focusedPane: PaneID?
    let tabPanes: Set<String>

    @Environment(ChatStore.self) private var chatStore: ChatStore?
    @Environment(ChatSidebarStore.self) private var store: ChatSidebarStore?

    func body(content: Content) -> some View {
        content
            .task(id: chatStore?.isAvailable) {
                guard chatStore?.isAvailable == true else { return }
                await store?.follow()
            }
            .onChange(of: focusedPane) { _, pane in
                Task { await store?.focusChanged(to: pane?.rawValue) }
            }
            .onChange(of: tabPanes, initial: true) { _, panes in
                Task { await store?.tabChanged(to: panes) }
            }
    }
}

/// The chat app's page. Anything that leaves the page opens in the browser, so
/// a link in a message can't replace the chat.
private struct ChatEmbedWebView: NSViewRepresentable {
    let url: URL
    let onFailure: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFailure: onFailure)
    }

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        // Otherwise white until the page's first paint, on a dark window.
        view.setValue(false, forKey: "drawsBackground")
        context.coordinator.requested = url
        view.load(URLRequest(url: url))
        return view
    }

    /// Compared with what was asked for: `view.url` is stale until a load commits.
    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.onFailure = onFailure
        guard context.coordinator.requested != url else { return }
        context.coordinator.requested = url
        view.load(URLRequest(url: url))
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var onFailure: () -> Void
        var requested: URL?

        init(onFailure: @escaping () -> Void) {
            self.onFailure = onFailure
        }

        func webView(
            _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            guard action.navigationType == .linkActivated, let url = action.request.url,
                  url.host != webView.url?.host
            else {
                decisionHandler(.allow)
                return
            }
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        }

        func webView(
            _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
            for action: WKNavigationAction, windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = action.request.url { NSWorkspace.shared.open(url) }
            return nil
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            onFailure()
        }
    }
}
