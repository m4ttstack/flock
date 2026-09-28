import FlockCore
import SwiftUI

/// The View menu's picker for the panes' three fixed terminal point sizes,
/// with a checkmark on the active one. Cmd-plus and Cmd-minus step the shown
/// rt modal's size while one is up and the panes' otherwise, stopping at
/// either end; each modal's resting size is set in Settings.
///
/// The step items are never disabled: a disabled item lets its key through to
/// the focused ghostty surface. Their actions read the stores when pressed,
/// because a Commands body is not reliably rebuilt after a store changes.
struct TerminalTextSizeMenu: View {
    let panes: TerminalTextSizeStore
    let modal: RtModalTextSizeStore
    let shownModalKind: () -> RtKind?

    var body: some View {
        Menu("Terminal Text") {
            Button("Bigger") { step(\.larger) }
                .keyboardShortcut("+", modifiers: .command)
            Button("Smaller") { step(\.smaller) }
                .keyboardShortcut("-", modifiers: .command)
            Section("Panes") {
                picker(active: panes.active, select: panes.select)
            }
        }
    }

    private func step(_ direction: KeyPath<TerminalTextSize, TerminalTextSize?>) {
        if let kind = shownModalKind() {
            if let next = modal.size(for: kind)[keyPath: direction] { modal.select(next, for: kind) }
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
