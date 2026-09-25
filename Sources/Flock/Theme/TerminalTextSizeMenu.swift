import SwiftUI

/// View menu pickers for the three fixed terminal point sizes, one for the
/// panes and one for the rt modal, each with a checkmark on its active size.
/// Cmd-plus and Cmd-minus step the modal's size while it is up and the
/// panes' otherwise, stopping at either end.
///
/// The step items are never disabled: a disabled item lets its key through to
/// the focused ghostty surface. Their actions read the stores when pressed,
/// because a Commands body is not reliably rebuilt after a store changes.
struct TerminalTextSizeMenu: View {
    let panes: TerminalTextSizeStore
    let modal: RtModalTextSizeStore
    let modalIsUp: () -> Bool

    var body: some View {
        Menu("Terminal Text") {
            Button("Bigger") { step(\.larger) }
                .keyboardShortcut("+", modifiers: .command)
            Button("Smaller") { step(\.smaller) }
                .keyboardShortcut("-", modifiers: .command)
            Section("Panes") {
                picker(active: panes.active, select: panes.select)
            }
            Section("rt Modal") {
                picker(active: modal.active, select: modal.select)
            }
        }
    }

    private func step(_ direction: KeyPath<TerminalTextSize, TerminalTextSize?>) {
        if modalIsUp() {
            if let next = modal.active[keyPath: direction] { modal.select(next) }
        } else {
            if let next = panes.active[keyPath: direction] { panes.select(next) }
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
