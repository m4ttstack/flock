import SwiftUI

/// The message field both compose surfaces (Quick send, Broadcast) share:
/// `surface0` fill, an `accent` stroke, identical text and padding treatment.
/// Only the box's own size and padding numbers differ between the two, so
/// both are parameters rather than a second copy of this view.
struct ChatComposeField: View {
    let theme: Theme
    @Binding var text: String
    let size: CGSize
    let cornerRadius: CGFloat
    let verticalPadding: CGFloat
    let horizontalPadding: CGFloat

    var body: some View {
        TextEditor(text: $text)
            .font(ChromeType.chatComposeFieldText)
            .foregroundStyle(theme.text)
            .scrollContentBackground(.hidden)
            .padding(.vertical, verticalPadding)
            .padding(.horizontal, horizontalPadding)
            .frame(width: size.width, height: size.height)
            .background(RoundedRectangle(cornerRadius: cornerRadius).fill(Color(theme.palette.surface0)))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(theme.accent, lineWidth: 1))
    }
}

/// The send button both compose surfaces share, down to the `⌘⏎` beside the
/// label at 67% of the label's own colour. Only `fill` differs: `accent` for
/// Quick send, `mauve` for Broadcast -- the one place the two surfaces are
/// deliberately not identical.
struct ChatComposeSendButton: View {
    let theme: Theme
    let title: String
    let fill: Color
    let size: CGSize
    let cornerRadius: CGFloat
    let verticalPadding: CGFloat
    let horizontalPadding: CGFloat
    let gap: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: gap) {
                Text(title).font(ChromeType.chatComposeSendLabel)
                Text("⌘⏎").font(ChromeType.chatComposeSendShortcut).opacity(0.67)
            }
            .foregroundStyle(Color(theme.palette.panelBg))
            .padding(.vertical, verticalPadding)
            .padding(.horizontal, horizontalPadding)
            .frame(width: size.width, height: size.height)
            .background(RoundedRectangle(cornerRadius: cornerRadius).fill(fill))
        }
        .buttonStyle(.plain)
        // The one binding for the `⌘⏎` this button already draws: disabled
        // state (`.disabled` at each call site) suppresses the shortcut the
        // same way it suppresses the click.
        .keyboardShortcut(.return, modifiers: .command)
    }
}
