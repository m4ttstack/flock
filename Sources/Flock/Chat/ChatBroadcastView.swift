import FlockCore
import SwiftUI

/// Chat broadcast: every pane on chat with a checkbox, select-all, one
/// message, and a `mauve` send button -- the one place it and Quick send's
/// `accent` button deliberately differ.
///
/// A broadcast's own two failure shapes differ in exit code: every pane
/// refusing still decodes (`ChatStore.broadcast` returns it, refusals
/// included), while an empty `--panes` throws and the store answers `nil`.
/// Either way, summarizing what actually happened is this view's job --
/// `ChatBroadcastSummary` is the pure rule for whether that is worth a toast.
struct ChatBroadcastView: View {
    let theme: Theme
    let onBack: () -> Void
    let onClose: () -> Void

    @Environment(ChatStore.self) private var chatStore
    @Environment(ToastCenter.self) private var toasts
    @State private var buddies: [ChatBuddy] = []
    @State private var checked: Set<String> = []
    @State private var message = ""

    /// `previewBuddies` exists only so a geometry test can measure a
    /// populated pane list without a live `ChatStore` in the environment --
    /// production call sites never pass it, and `.task` below overwrites it
    /// with the real fetch regardless.
    init(theme: Theme, onBack: @escaping () -> Void, onClose: @escaping () -> Void, previewBuddies: [ChatBuddy]? = nil) {
        self.theme = theme
        self.onBack = onBack
        self.onClose = onClose
        let seeded = previewBuddies ?? []
        self._buddies = State(initialValue: seeded)
        self._checked = State(initialValue: Set(seeded.filter(Self.isSelectable).map(\.paneID)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ChatSubviewHeader(theme: theme, title: "Broadcast to panes", width: ChromeMetrics.ChatBroadcast.width, onBack: onBack, onClose: onClose)
            selectHead
            ForEach(buddies, id: \.paneID) { buddy in
                paneRow(buddy)
            }
            fieldBand
        }
        .frame(width: ChromeMetrics.ChatBroadcast.width)
        // `previewBuddies` already seeded `buddies`; a real fetch would
        // overwrite deterministic preview data with whatever an inert test
        // store answers, which is exactly the flake a geometry test cannot
        // have.
        .task {
            guard buddies.isEmpty else { return }
            guard let peek = await chatStore.peek() else { return }
            buddies = peek.buddies
            checked = Set(peek.buddies.filter(Self.isSelectable).map(\.paneID))
        }
    }

    /// Not `private`: a geometry test measures a band's own height directly
    /// off its `.frame`, the same way `ChatPopover`'s own bands are read.
    var selectHead: some View {
        HStack(spacing: 0) {
            Text("PANES").font(ChromeType.chatPopoverSectionLabel).foregroundStyle(theme.overlay0)
            Spacer(minLength: 0)
            Button(action: selectAll) {
                Text("Select all").font(ChromeType.chatBroadcastSelectAll).foregroundStyle(theme.accent)
            }
            .buttonStyle(.plain)
        }
        .padding(.top, ChromeMetrics.ChatBroadcast.SelectHead.topPadding)
        .padding(.trailing, ChromeMetrics.ChatBroadcast.SelectHead.trailingPadding)
        .padding(.bottom, ChromeMetrics.ChatBroadcast.SelectHead.bottomPadding)
        .padding(.leading, ChromeMetrics.ChatBroadcast.SelectHead.leadingPadding)
        .frame(width: ChromeMetrics.ChatBroadcast.width, height: ChromeMetrics.ChatBroadcast.SelectHead.height, alignment: .top)
    }

    func paneRow(_ buddy: ChatBuddy) -> some View {
        let selectable = Self.isSelectable(buddy)
        let isChecked = checked.contains(buddy.paneID)
        return Button(action: { toggle(buddy) }) {
            HStack(spacing: ChromeMetrics.ChatBroadcast.PaneRow.gap) {
                checkbox(checked: isChecked)
                Circle()
                    .fill(dotColor(for: buddy.status))
                    .frame(width: ChromeMetrics.ChatBroadcast.PaneRow.dotSize, height: ChromeMetrics.ChatBroadcast.PaneRow.dotSize)
                VStack(alignment: .leading, spacing: ChromeMetrics.ChatBroadcast.PaneRow.stackGap) {
                    Text(buddy.handle).font(ChromeType.chatPeekHandle).foregroundStyle(theme.text)
                    Text(location(for: buddy)).font(ChromeType.chatPeekLocation).foregroundStyle(theme.overlay0)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, ChromeMetrics.ChatBroadcast.PaneRow.verticalPadding)
            .padding(.horizontal, ChromeMetrics.ChatBroadcast.PaneRow.horizontalPadding)
            .frame(width: ChromeMetrics.ChatBroadcast.width, height: ChromeMetrics.ChatBroadcast.PaneRow.height)
            .background(isChecked ? Color(theme.palette.activeRowBg) : Color.clear)
        }
        .buttonStyle(.plain)
        .disabled(!selectable)
    }

    private func checkbox(checked isChecked: Bool) -> some View {
        RoundedRectangle(cornerRadius: ChromeMetrics.ChatBroadcast.PaneRow.checkboxCornerRadius)
            .fill(isChecked ? theme.accent : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: ChromeMetrics.ChatBroadcast.PaneRow.checkboxCornerRadius)
                    .strokeBorder(isChecked ? Color.clear : theme.surface1, lineWidth: 1)
            )
            .overlay {
                if isChecked {
                    Image(systemName: "checkmark")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(Color(theme.palette.panelBg))
                        .frame(width: ChromeMetrics.ChatBroadcast.PaneRow.checkTickSize, height: ChromeMetrics.ChatBroadcast.PaneRow.checkTickSize)
                }
            }
            .frame(width: ChromeMetrics.ChatBroadcast.PaneRow.checkboxSize, height: ChromeMetrics.ChatBroadcast.PaneRow.checkboxSize)
    }

    /// `alignment: .topLeading`, matching Quick send's own field band: the
    /// field happens to fill the band's own width today (its declared size
    /// plus padding sums to the band width), not anything this frame can
    /// rely on if either number ever moves.
    var fieldBand: some View {
        VStack(alignment: .leading, spacing: ChromeMetrics.ChatBroadcast.FieldBand.gap) {
            ChatComposeField(
                theme: theme, text: $message, size: ChromeMetrics.ChatBroadcast.FieldBand.fieldSize,
                cornerRadius: ChromeMetrics.ChatBroadcast.FieldBand.fieldCornerRadius,
                verticalPadding: ChromeMetrics.ChatBroadcast.FieldBand.fieldVerticalPadding,
                horizontalPadding: ChromeMetrics.ChatBroadcast.FieldBand.fieldHorizontalPadding
            )
            HStack(spacing: 0) {
                Text("\(checked.count) panes").font(ChromeType.chatComposeFooterHint).foregroundStyle(theme.overlay0)
                Spacer(minLength: 0)
                ChatComposeSendButton(
                    theme: theme, title: "Broadcast", fill: theme.mauve, size: ChromeMetrics.ChatBroadcast.FieldBand.sendButtonSize,
                    cornerRadius: ChromeMetrics.ChatBroadcast.FieldBand.sendButtonCornerRadius,
                    verticalPadding: ChromeMetrics.ChatBroadcast.FieldBand.sendButtonVerticalPadding,
                    horizontalPadding: ChromeMetrics.ChatBroadcast.FieldBand.sendButtonHorizontalPadding,
                    gap: ChromeMetrics.ChatBroadcast.FieldBand.sendButtonGap, action: send
                )
                .disabled(checked.isEmpty)
            }
            .frame(height: ChromeMetrics.ChatBroadcast.FieldBand.footerHeight)
        }
        .padding(ChromeMetrics.ChatBroadcast.FieldBand.padding)
        .frame(width: ChromeMetrics.ChatBroadcast.width, height: ChromeMetrics.ChatBroadcast.FieldBand.height, alignment: .topLeading)
        .overlay(alignment: .top) {
            Rectangle().fill(Color(theme.palette.surface0)).frame(height: 1)
        }
    }

    /// A buddy whose status is not one of chat's own live words is not
    /// currently signed in, and cannot be selected: forcing it out of
    /// `checked` here as well as disabling its row keeps the two in
    /// agreement even if a peek refresh drops a pane mid-selection.
    private static func isSelectable(_ buddy: ChatBuddy) -> Bool {
        AgentStatus(rawValue: buddy.status) != nil
    }

    private func dotColor(for status: String) -> Color {
        switch AgentStatus(rawValue: status) ?? .unknown {
        case .working: theme.yellow
        case .idle: theme.green
        case .done: theme.accent
        case .blocked: theme.red
        case .unknown: theme.overlay0
        }
    }

    private func location(for buddy: ChatBuddy) -> String {
        if let repo = buddy.repo, let branch = buddy.branch {
            return "\(repo) / \(branch)"
        }
        return buddy.title ?? ""
    }

    private func toggle(_ buddy: ChatBuddy) {
        if checked.contains(buddy.paneID) {
            checked.remove(buddy.paneID)
        } else {
            checked.insert(buddy.paneID)
        }
    }

    private func selectAll() {
        checked = Set(buddies.filter(Self.isSelectable).map(\.paneID))
    }

    private func send() {
        let panes = Array(checked)
        let body = message
        Task {
            guard let broadcast = await chatStore.broadcast(panes: panes, body: body) else { return }
            if let toastMessage = ChatBroadcastSummary.message(for: broadcast) {
                toasts.show(toastMessage, kind: .info)
            } else {
                message = ""
            }
        }
    }
}
