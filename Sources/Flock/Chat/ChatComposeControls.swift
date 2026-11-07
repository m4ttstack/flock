import SwiftUI

/// The message field the compose surfaces (Quick send, Broadcast, Slack
/// support) share: `lift` fill, a `hair` edge that turns `hairFocus` while
/// focused, identical text and padding treatment. Only the box's own size and
/// padding numbers differ between them, so those are parameters rather than a
/// second copy of this view. Focus lives with the caller, which applies
/// `.focused` to this view and passes the result back as `isFocused`.
struct ChatComposeField: View {
    let theme: Theme
    @Binding var text: String
    let size: CGSize
    let cornerRadius: CGFloat
    let verticalPadding: CGFloat
    let horizontalPadding: CGFloat
    var isFocused = false

    var body: some View {
        TextEditor(text: $text)
            .font(ChromeType.chatComposeFieldText)
            .foregroundStyle(theme.textStrong)
            .scrollContentBackground(.hidden)
            .padding(.vertical, verticalPadding)
            .padding(.horizontal, horizontalPadding)
            .frame(width: size.width, height: size.height)
            .background(RoundedRectangle(cornerRadius: cornerRadius).fill(theme.lift))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(isFocused ? theme.hairFocus : theme.hair, lineWidth: 1))
    }
}

/// The send button every compose surface shares: a `lift` fill with a
/// `textStrong` label and the `⌘⏎` beside it at 67% of the label's colour.
/// Disabled reads from the environment (`.disabled` at each call site), which
/// fades the fill and drops the label to `textLabel`.
struct ChatComposeSendButton: View {
    let theme: Theme
    let title: String
    let size: CGSize
    let cornerRadius: CGFloat
    let verticalPadding: CGFloat
    let horizontalPadding: CGFloat
    let gap: CGFloat
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: gap) {
                Text(title).font(ChromeType.chatComposeSendLabel)
                Text("⌘⏎").font(ChromeType.chatComposeSendShortcut).opacity(0.67)
            }
            .foregroundStyle(isEnabled ? theme.textStrong : theme.textLabel)
            .padding(.vertical, verticalPadding)
            .padding(.horizontal, horizontalPadding)
            .frame(width: size.width, height: size.height)
            .background(RoundedRectangle(cornerRadius: cornerRadius).fill(theme.lift.opacity(isEnabled ? 1 : 0.5)))
        }
        .buttonStyle(.plain)
        // The one binding for the `⌘⏎` this button already draws: disabled
        // state (`.disabled` at each call site) suppresses the shortcut the
        // same way it suppresses the click.
        .keyboardShortcut(.return, modifiers: .command)
    }
}
