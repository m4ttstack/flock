import FlockCore
import SwiftUI

/// Chat quick send: one target chip selected at a time (`targets` prints
/// rooms before people, prefixes intact -- `quick-send --to` takes exactly
/// what it printed), a message field, and a send button that fills `accent`.
struct ChatQuickSendView: View {
    let theme: Theme
    let status: ChatStatus?
    let onBack: () -> Void
    let onClose: () -> Void

    @Environment(ChatStore.self) private var chatStore
    @State private var targets: [String] = []
    @State private var selectedTarget: String?
    @State private var message = ""

    /// `previewTargets` exists only so a geometry test can measure a
    /// populated chip row without a live `ChatStore` in the environment --
    /// production call sites never pass it, and `.task` below overwrites it
    /// with the real fetch regardless.
    init(theme: Theme, status: ChatStatus?, onBack: @escaping () -> Void, onClose: @escaping () -> Void, previewTargets: [String]? = nil) {
        self.theme = theme
        self.status = status
        self.onBack = onBack
        self.onClose = onClose
        self._targets = State(initialValue: previewTargets ?? [])
        self._selectedTarget = State(initialValue: previewTargets?.first)
    }

    private var canSend: Bool {
        ChatPresence.canSend(status) && selectedTarget != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ChatSubviewHeader(theme: theme, title: "Quick send", width: ChromeMetrics.ChatQuickSend.width, onBack: onBack, onClose: onClose)
            targetBand
            fieldBand
        }
        .frame(width: ChromeMetrics.ChatQuickSend.width)
        // `previewTargets` already seeded `targets`; a real fetch would
        // overwrite deterministic preview data with whatever an inert test
        // store answers, which is exactly the flake a geometry test cannot
        // have.
        .task {
            guard targets.isEmpty else { return }
            guard let fetched = await chatStore.targets() else { return }
            targets = fetched.rooms + fetched.people
            selectedTarget = targets.first
        }
    }

    /// Not `private`: a geometry test measures a band's own height directly
    /// off its `.frame`, the same way `ChatPopover`'s own bands are read.
    ///
    /// `alignment: .topLeading`, never plain `.top`: the label and chip row
    /// are narrower than the band, so a bare `.top` (top-CENTER) would
    /// center this content instead of holding it at the band's own 14pt
    /// inset the field and footer below it share.
    var targetBand: some View {
        VStack(alignment: .leading, spacing: ChromeMetrics.ChatQuickSend.TargetBand.gap) {
            Text("TO").font(ChromeType.chatPopoverSectionLabel).foregroundStyle(theme.overlay0)
            HStack(spacing: ChromeMetrics.ChatQuickSend.TargetBand.chipGap) {
                ForEach(targets, id: \.self) { target in
                    chip(target)
                }
            }
        }
        .padding(.top, ChromeMetrics.ChatQuickSend.TargetBand.topPadding)
        .padding(.trailing, ChromeMetrics.ChatQuickSend.TargetBand.trailingPadding)
        .padding(.bottom, ChromeMetrics.ChatQuickSend.TargetBand.bottomPadding)
        .padding(.leading, ChromeMetrics.ChatQuickSend.TargetBand.leadingPadding)
        .frame(width: ChromeMetrics.ChatQuickSend.width, height: ChromeMetrics.ChatQuickSend.TargetBand.height, alignment: .topLeading)
    }

    private func chip(_ target: String) -> some View {
        let isSelected = selectedTarget == target
        return Button(action: { selectedTarget = target }) {
            Text(target)
                .font(isSelected ? ChromeType.chatQuickSendChipSelected : ChromeType.chatQuickSendChipUnselected)
                .foregroundStyle(isSelected ? Color(theme.palette.panelBg) : theme.subtext0)
                .padding(.vertical, ChromeMetrics.ChatQuickSend.TargetBand.chipVerticalPadding)
                .padding(.horizontal, ChromeMetrics.ChatQuickSend.TargetBand.chipHorizontalPadding)
                .frame(height: ChromeMetrics.ChatQuickSend.TargetBand.chipHeight)
                .background(
                    RoundedRectangle(cornerRadius: ChromeMetrics.ChatQuickSend.TargetBand.chipCornerRadius)
                        .fill(isSelected ? theme.accent : Color(theme.palette.surface0))
                )
        }
        .buttonStyle(.plain)
    }

    /// `alignment: .topLeading` for the same reason `targetBand` needs it:
    /// the field happens to fill the band's own width today, but that is the
    /// field's declared size plus its padding summing to the band width, not
    /// anything this frame can rely on if either number ever moves.
    var fieldBand: some View {
        VStack(alignment: .leading, spacing: ChromeMetrics.ChatQuickSend.FieldBand.gap) {
            ChatComposeField(
                theme: theme, text: $message, size: ChromeMetrics.ChatQuickSend.FieldBand.fieldSize,
                cornerRadius: ChromeMetrics.ChatQuickSend.FieldBand.fieldCornerRadius,
                verticalPadding: ChromeMetrics.ChatQuickSend.FieldBand.fieldVerticalPadding,
                horizontalPadding: ChromeMetrics.ChatQuickSend.FieldBand.fieldHorizontalPadding
            )
            HStack(spacing: 0) {
                Text(footerHint)
                    .font(ChromeType.chatComposeFooterHint)
                    .foregroundStyle(theme.overlay0)
                Spacer(minLength: 0)
                ChatComposeSendButton(
                    theme: theme, title: "Send", fill: theme.accent, size: ChromeMetrics.ChatQuickSend.FieldBand.sendButtonSize,
                    cornerRadius: ChromeMetrics.ChatQuickSend.FieldBand.sendButtonCornerRadius,
                    verticalPadding: ChromeMetrics.ChatQuickSend.FieldBand.sendButtonVerticalPadding,
                    horizontalPadding: ChromeMetrics.ChatQuickSend.FieldBand.sendButtonHorizontalPadding,
                    gap: ChromeMetrics.ChatQuickSend.FieldBand.sendButtonGap, action: send
                )
                .disabled(!canSend)
            }
            .frame(height: ChromeMetrics.ChatQuickSend.FieldBand.footerHeight)
        }
        .padding(.top, ChromeMetrics.ChatQuickSend.FieldBand.topPadding)
        .padding(.trailing, ChromeMetrics.ChatQuickSend.FieldBand.trailingPadding)
        .padding(.bottom, ChromeMetrics.ChatQuickSend.FieldBand.bottomPadding)
        .padding(.leading, ChromeMetrics.ChatQuickSend.FieldBand.leadingPadding)
        .frame(width: ChromeMetrics.ChatQuickSend.width, height: ChromeMetrics.ChatQuickSend.FieldBand.height, alignment: .topLeading)
    }

    /// Signed out is not a failure, so the footer says why sending is
    /// disabled rather than staying blank -- the send button's own
    /// `canSend` is what actually enforces it. Not `private`: a test reads
    /// this directly, the same way it reads `targetBand`/`fieldBand`.
    var footerHint: String {
        guard let handle = status?.handle, status?.signedIn == true else { return "Sign in to send" }
        return "sent as \(handle)"
    }

    private func send() {
        guard let target = selectedTarget else { return }
        let body = message
        Task {
            guard await chatStore.quickSend(to: target, body: body) else { return }
            message = ""
        }
    }
}
