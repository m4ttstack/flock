import AppKit
import FlockCore
import SwiftUI

/// The one inline rename editor, opened in place of whatever label is being
/// renamed (a pane's legend title, a tab's label, a rail row's name). It owns
/// only the text and how the edit ENDS; what a commit means is
/// `RenameEditor`'s, through `SessionViewModel.commitRename`.
///
/// Three ways out, and exactly one of them ever fires: Return commits, Esc
/// cancels, and losing focus commits (clicking elsewhere is an accept, the
/// way every macOS inline rename behaves). `settled` is what makes that
/// exclusive -- Esc removes this view, which itself drops focus, so without
/// it a cancel would be followed immediately by a commit of the very text it
/// just discarded.
///
/// Callers must disable their own drag arming while this is showing (the
/// spec's Rename bullet): a press inside the field that arms a drag never
/// reaches the text, so selection and caret placement stop working.
struct InlineRenameField: View {
    let theme: Theme
    let font: Font
    let accessibilityIdentifier: String
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    @State private var text: String
    @State private var settled = false
    @FocusState private var focused: Bool

    init(
        theme: Theme, font: Font, initialText: String, accessibilityIdentifier: String,
        onCommit: @escaping (String) -> Void, onCancel: @escaping () -> Void
    ) {
        self.theme = theme
        self.font = font
        self.accessibilityIdentifier = accessibilityIdentifier
        self.onCommit = onCommit
        self.onCancel = onCancel
        _text = State(initialValue: initialText)
    }

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(font)
            .foregroundStyle(theme.textStrong)
            .focused($focused)
            .onSubmit { settle { onCommit(text) } }
            .onExitCommand { settle { onCancel() } }
            .onChange(of: focused) { _, isFocused in
                guard !isFocused else { return }
                settle { onCommit(text) }
            }
            .frame(minWidth: ChromeMetrics.Rename.minimumWidth)
            .padding(.horizontal, ChromeMetrics.Rename.horizontalPadding)
            .background(
                RoundedRectangle(cornerRadius: ChromeMetrics.Rename.cornerRadius)
                    .fill(theme.pane)
                    .overlay(
                        RoundedRectangle(cornerRadius: ChromeMetrics.Rename.cornerRadius)
                            .strokeBorder(theme.accent, lineWidth: ChromeMetrics.ruleWidth)
                    )
            )
            // Both, and neither alone: `focused` is what SwiftUI's own
            // machinery (`onSubmit`, `onExitCommand`, the focus-loss commit)
            // reads, and the claim is what actually moves AppKit's first
            // responder, which SwiftUI's one-shot request does not do while a
            // pane's terminal is holding it. The claim also owns the
            // select-all, since it is the only thing that knows when the
            // field really took the keyboard.
            .onAppear { focused = true }
            .background(FirstResponderClaim())
            .accessibilityIdentifier(accessibilityIdentifier)
    }

    private func settle(_ action: () -> Void) {
        guard !settled else { return }
        settled = true
        action()
    }
}

/// The hover-reveal close control a tab and an attention toast carry. Present
/// in the layout at all times so a row never reflows as the pointer crosses
/// it; only its opacity follows the hover.
struct HoverCloseButton: View {
    let theme: Theme
    let isRevealed: Bool
    let help: String
    let accessibilityIdentifier: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(ChromeType.closeSymbol)
                .foregroundStyle(isHovering ? theme.textStrong : theme.textLabel)
                .frame(width: ChromeMetrics.CloseButton.size, height: ChromeMetrics.CloseButton.size)
                .background(
                    RoundedRectangle(cornerRadius: ChromeMetrics.CloseButton.cornerRadius)
                        .fill(theme.selection)
                        .opacity(isHovering ? 1 : 0)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .opacity(isRevealed ? 1 : 0)
        .allowsHitTesting(isRevealed)
        .help(help)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}
