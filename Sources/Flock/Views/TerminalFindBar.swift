import FlockCore
import SwiftUI

/// Cmd+F's bar, drawn over a pane's terminal. What it finds and highlights is
/// libghostty's; this owns the needle, the keys typed into it, and handing
/// the keyboard back to the terminal.
///
/// Esc with text in the field returns to the terminal and leaves the matches
/// lit, the way Ghostty does; Esc on an empty field, or Esc again in the
/// terminal, closes the bar.
struct TerminalFindBar: View {
    let theme: Theme
    @Bindable var search: TerminalSearch
    let onSearch: (String) -> Void
    let onNavigate: (_ forward: Bool) -> Void
    let onClose: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: ChromeMetrics.FindBar.buttonSpacing) {
            field
            FindBarButton(theme: theme, symbol: "chevron.up", help: "Next Match (⌘G)", id: "next") {
                onNavigate(true)
            }
            FindBarButton(theme: theme, symbol: "chevron.down", help: "Previous Match (⇧⌘G)", id: "previous") {
                onNavigate(false)
            }
            FindBarButton(theme: theme, symbol: "xmark", help: "Close (Esc)", id: "close", action: onClose)
        }
        .padding(ChromeMetrics.FindBar.padding)
        .background(
            RoundedRectangle(cornerRadius: ChromeMetrics.FindBar.cornerRadius)
                .fill(theme.chrome)
                .overlay(
                    RoundedRectangle(cornerRadius: ChromeMetrics.FindBar.cornerRadius)
                        .strokeBorder(theme.rule, lineWidth: ChromeMetrics.ruleWidth)
                )
                .shadow(color: .black.opacity(0.25), radius: ChromeMetrics.FindBar.shadowRadius, y: 2)
        )
        .task(id: search.needle) {
            let needle = search.needle
            try? await Task.sleep(for: TerminalSearch.debounce(for: needle))
            guard !Task.isCancelled else { return }
            onSearch(needle)
        }
        .onChange(of: search.fieldHasFocus, initial: true) { _, wanted in
            if wanted { focused = true }
        }
        .onChange(of: focused) { _, isFocused in
            search.fieldHasFocus = isFocused
        }
    }

    private var field: some View {
        TextField("Find", text: $search.needle)
            .textFieldStyle(.plain)
            .font(ChromeType.findField)
            .foregroundStyle(theme.textStrong)
            .focused($focused)
            .frame(width: ChromeMetrics.FindBar.fieldWidth)
            .padding(.leading, ChromeMetrics.FindBar.fieldHorizontalPadding)
            .padding(.trailing, ChromeMetrics.FindBar.countReserve)
            .padding(.vertical, ChromeMetrics.FindBar.fieldVerticalPadding)
            .background(
                RoundedRectangle(cornerRadius: ChromeMetrics.FindBar.fieldCornerRadius)
                    .fill(theme.pane)
                    .overlay(
                        RoundedRectangle(cornerRadius: ChromeMetrics.FindBar.fieldCornerRadius)
                            .strokeBorder(focused ? theme.accent : theme.rule, lineWidth: ChromeMetrics.ruleWidth)
                    )
            )
            .overlay(alignment: .trailing) {
                if let count = search.countLabel {
                    Text(count)
                        .font(ChromeType.findCount)
                        .foregroundStyle(theme.textLabel)
                        .padding(.trailing, ChromeMetrics.FindBar.fieldHorizontalPadding)
                        .allowsHitTesting(false)
                }
            }
            .onSubmit { onNavigate(true) }
            .onKeyPress(.return, phases: .down) { press in
                guard press.modifiers.contains(.shift) else { return .ignored }
                onNavigate(false)
                return .handled
            }
            .onKeyPress(characters: ["g", "G"], phases: .down) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                onNavigate(!press.modifiers.contains(.shift))
                return .handled
            }
            .onExitCommand {
                if search.needle.isEmpty {
                    onClose()
                } else {
                    search.fieldHasFocus = false
                }
            }
            // `@FocusState` alone loses to a terminal already holding first
            // responder; see `FirstResponderClaim`. Present only while the
            // field is wanted, and claimed once per request, so the terminal
            // taking the keyboard back is never undone by a later pass.
            .background {
                if search.fieldHasFocus {
                    FirstResponderClaim(request: search.focusRequest)
                }
            }
            .accessibilityIdentifier("flock.pane.find.field")
    }
}

private struct FindBarButton: View {
    let theme: Theme
    let symbol: String
    let help: String
    let id: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(ChromeType.findSymbol)
                .foregroundStyle(isHovering ? theme.textStrong : theme.textLabel)
                .frame(width: ChromeMetrics.FindBar.buttonSize, height: ChromeMetrics.FindBar.buttonSize)
                .background(
                    RoundedRectangle(cornerRadius: ChromeMetrics.FindBar.buttonCornerRadius)
                        .fill(theme.selection)
                        .opacity(isHovering ? 1 : 0)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityIdentifier("flock.pane.find.\(id)")
    }
}
