import SwiftUI

/// View menu picker for the three fixed terminal point sizes, with the
/// standard macOS zoom keybindings (Cmd-minus/Cmd-0/Cmd-plus) and a
/// checkmark on the active one.
struct TerminalTextSizeMenu: View {
    let store: TerminalTextSizeStore

    var body: some View {
        Menu("Terminal Text") {
            ForEach(TerminalTextSize.allCases, id: \.self) { size in
                Button {
                    store.select(size)
                } label: {
                    if size == store.active {
                        Label(size.displayName, systemImage: "checkmark")
                    } else {
                        Text(size.displayName)
                    }
                }
                .keyboardShortcut(shortcut(for: size))
            }
        }
    }

    private func shortcut(for size: TerminalTextSize) -> KeyboardShortcut {
        switch size {
        case .compact: KeyboardShortcut("-", modifiers: .command)
        case .regular: KeyboardShortcut("0", modifiers: .command)
        case .large: KeyboardShortcut("+", modifiers: .command)
        }
    }
}
