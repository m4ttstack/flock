import FlockCore
import SwiftUI

/// Chat peek: everyone visible on chat, with an unread pill and a jump
/// affordance, then every room's own unread tally below.
///
/// Peek's own `jump` verb only names a pane; it moves nothing by itself, so
/// clicking a row asks the store for that pane id and hands it to `onJump`,
/// which focuses the workspace, tab and pane FROM FLOCK'S OWN MODEL rather
/// than anything the verb carries.
struct ChatPeekView: View {
    let theme: Theme
    let onBack: () -> Void
    let onClose: () -> Void
    let onJump: (PaneID) -> Void

    @Environment(ChatStore.self) private var chatStore
    @State private var peek: ChatPeek?

    /// `previewPeek` exists only so a geometry test can measure a fully
    /// populated layout without a live `ChatStore` in the environment --
    /// production call sites never pass it, and `.task` below overwrites it
    /// with the real fetch regardless.
    init(
        theme: Theme, onBack: @escaping () -> Void, onClose: @escaping () -> Void, onJump: @escaping (PaneID) -> Void,
        previewPeek: ChatPeek? = nil
    ) {
        self.theme = theme
        self.onBack = onBack
        self.onClose = onClose
        self.onJump = onJump
        self._peek = State(initialValue: previewPeek)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ChatSubviewHeader(theme: theme, title: "Chat peek", width: ChromeMetrics.ChatPeek.width, onBack: onBack, onClose: onClose)
            label("PANES ON CHAT")
            ForEach(peek?.buddies ?? [], id: \.paneID) { buddy in
                paneRow(buddy)
            }
            label("ROOMS")
            ForEach(Array((peek?.rooms ?? []).enumerated()), id: \.element.room) { index, room in
                roomRow(room, isFirst: index == 0)
            }
        }
        .frame(width: ChromeMetrics.ChatPeek.width)
        // `previewPeek` already seeded `peek`; a real fetch would overwrite
        // deterministic preview data with whatever an inert test store
        // answers, which is exactly the flake a geometry test cannot have.
        .task {
            guard peek == nil else { return }
            peek = await chatStore.peek()
        }
    }

    /// Not `private`: a geometry test measures a band's own height directly
    /// off its `.frame`, the same way `ChatPopover`'s own bands are read.
    func label(_ text: String) -> some View {
        Text(text)
            .font(ChromeType.chatPopoverSectionLabel)
            .foregroundStyle(theme.overlay0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, ChromeMetrics.ChatPeek.Label.topPadding)
            .padding(.trailing, ChromeMetrics.ChatPeek.Label.trailingPadding)
            .padding(.bottom, ChromeMetrics.ChatPeek.Label.bottomPadding)
            .padding(.leading, ChromeMetrics.ChatPeek.Label.leadingPadding)
            .frame(width: ChromeMetrics.ChatPeek.width, height: ChromeMetrics.ChatPeek.Label.height, alignment: .top)
    }

    /// Highlighted exactly when there is unread to draw attention to -- the
    /// row's fill is a "this needs you" mark, not a plain zebra stripe, so a
    /// buddy with nothing new reads the same as the ground around it.
    func paneRow(_ buddy: ChatBuddy) -> some View {
        let hasUnread = buddy.unread > 0
        return Button(action: { jump(to: buddy) }) {
            HStack(spacing: ChromeMetrics.ChatPeek.PaneRow.gap) {
                Circle()
                    .fill(dotColor(for: buddy.status))
                    .frame(width: ChromeMetrics.ChatPeek.PaneRow.dotSize, height: ChromeMetrics.ChatPeek.PaneRow.dotSize)
                VStack(alignment: .leading, spacing: ChromeMetrics.ChatPeek.PaneRow.stackGap) {
                    Text(buddy.handle).font(ChromeType.chatPeekHandle).foregroundStyle(theme.text)
                    Text(location(for: buddy)).font(ChromeType.chatPeekLocation).foregroundStyle(theme.overlay0)
                }
                Spacer(minLength: 0)
                if hasUnread { unreadPill(buddy.unread) }
                Image(systemName: "arrow.turn.up.right")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(theme.overlay0)
                    .frame(width: ChromeMetrics.ChatPeek.PaneRow.jumpIconSize.width, height: ChromeMetrics.ChatPeek.PaneRow.jumpIconSize.height)
            }
            .padding(.vertical, ChromeMetrics.ChatPeek.PaneRow.verticalPadding)
            .padding(.horizontal, ChromeMetrics.ChatPeek.PaneRow.horizontalPadding)
            .frame(width: ChromeMetrics.ChatPeek.width, height: ChromeMetrics.ChatPeek.PaneRow.height)
            .background(hasUnread ? Color(theme.palette.activeRowBg) : Color.clear)
        }
        .buttonStyle(.plain)
    }

    func roomRow(_ room: ChatPeekRoom, isFirst: Bool) -> some View {
        HStack(spacing: ChromeMetrics.ChatPeek.RoomRow.gap) {
            Text(room.room).font(ChromeType.chatPeekRoomName).foregroundStyle(theme.subtext0)
            Spacer(minLength: 0)
            if room.unread > 0 { unreadPill(room.unread) }
        }
        .padding(.vertical, ChromeMetrics.ChatPeek.RoomRow.verticalPadding)
        .padding(.horizontal, ChromeMetrics.ChatPeek.RoomRow.horizontalPadding)
        .frame(
            width: ChromeMetrics.ChatPeek.width,
            height: isFirst ? ChromeMetrics.ChatPeek.RoomRow.firstHeight : ChromeMetrics.ChatPeek.RoomRow.subsequentHeight
        )
    }

    private func unreadPill(_ count: Int) -> some View {
        Text("\(count)")
            .font(ChromeType.chatPeekUnreadCount)
            .foregroundStyle(Color(theme.palette.panelBg))
            .padding(.vertical, ChromeMetrics.ChatPeek.PaneRow.pillVerticalPadding)
            .padding(.horizontal, ChromeMetrics.ChatPeek.PaneRow.pillHorizontalPadding)
            .frame(width: ChromeMetrics.ChatPeek.PaneRow.pillSize.width, height: ChromeMetrics.ChatPeek.PaneRow.pillSize.height)
            .background(RoundedRectangle(cornerRadius: ChromeMetrics.ChatPeek.PaneRow.pillCornerRadius).fill(theme.accent))
    }

    private func location(for buddy: ChatBuddy) -> String {
        if let repo = buddy.repo, let branch = buddy.branch {
            return "\(repo) / \(branch)"
        }
        return buddy.title ?? ""
    }

    /// Chat peek's own reduced palette (yellow/green/accent/red), not the
    /// pane chrome's own agent-status mark: `done` reads `accent` here, never
    /// `teal`, and an unrecognised word (a buddy no longer signed in) is
    /// `overlay0` rather than any of the four live colours.
    private func dotColor(for status: String) -> Color {
        switch AgentStatus(rawValue: status) ?? .unknown {
        case .working: theme.yellow
        case .idle: theme.green
        case .done: theme.accent
        case .blocked: theme.red
        case .unknown: theme.overlay0
        }
    }

    private func jump(to buddy: ChatBuddy) {
        Task {
            guard let result = await chatStore.jump(handle: buddy.handle) else { return }
            onJump(PaneID(rawValue: result.paneID))
        }
    }
}
