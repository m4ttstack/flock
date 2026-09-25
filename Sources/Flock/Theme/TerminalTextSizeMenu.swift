import SwiftUI

/// View menu picker for the three fixed terminal point sizes, with a
/// checkmark on the active one. Cmd-plus and Cmd-minus step through them,
/// stopping at either end.
struct TerminalTextSizeMenu: View {
    let store: TerminalTextSizeStore

    var body: some View {
        Menu("Terminal Text") {
            Button("Bigger") {
                if let larger = store.active.larger { store.select(larger) }
            }
            .keyboardShortcut("+", modifiers: .command)
            .disabled(store.active.larger == nil)
            Button("Smaller") {
                if let smaller = store.active.smaller { store.select(smaller) }
            }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(store.active.smaller == nil)
            Divider()
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
            }
        }
    }
}
