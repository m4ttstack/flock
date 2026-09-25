import SwiftUI

/// View menu pickers for the three fixed terminal point sizes, one for the
/// panes and one for the rt modal, each with a checkmark on its active size.
/// Cmd-plus and Cmd-minus step the modal's size while it is up and the
/// panes' otherwise, stopping at either end.
struct TerminalTextSizeMenu: View {
    let panes: TerminalTextSizeStore
    let modal: RtModalTextSizeStore
    let modalIsUp: Bool

    var body: some View {
        Menu("Terminal Text") {
            let stepped = modalIsUp ? modal.active : panes.active
            Button(modalIsUp ? "Bigger in rt Modal" : "Bigger") {
                if let larger = stepped.larger { select(larger) }
            }
            .keyboardShortcut("+", modifiers: .command)
            .disabled(stepped.larger == nil)
            Button(modalIsUp ? "Smaller in rt Modal" : "Smaller") {
                if let smaller = stepped.smaller { select(smaller) }
            }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(stepped.smaller == nil)
            Section("Panes") {
                picker(active: panes.active, select: panes.select)
            }
            Section("rt Modal") {
                picker(active: modal.active, select: modal.select)
            }
        }
    }

    private func select(_ size: TerminalTextSize) {
        if modalIsUp {
            modal.select(size)
        } else {
            panes.select(size)
        }
    }

    private func picker(active: TerminalTextSize, select: @escaping (TerminalTextSize) -> Void) -> some View {
        ForEach(TerminalTextSize.allCases, id: \.self) { size in
            Button {
                select(size)
            } label: {
                if size == active {
                    Label(size.displayName, systemImage: "checkmark")
                } else {
                    Text(size.displayName)
                }
            }
        }
    }
}
