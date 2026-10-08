import FlockCore
import SwiftUI

/// A pin's Claude Account submenu. Draws nothing while cswap is not
/// detected.
struct ClaudeAccountSubmenu: View {
    let pin: PinnedWorkspace
    let viewModel: SessionViewModel

    @Environment(CswapStore.self) private var cswap: CswapStore?

    var body: some View {
        let entries = ClaudeAccountMenu.entries(saved: pin.claudeAccount, accounts: cswap?.accounts)
        if !entries.isEmpty {
            Picker(ClaudeAccountMenu.title, selection: selection(entries)) {
                ForEach(entries, id: \.account) { entry in
                    Text(entry.label).tag(entry.account)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("flock.pin.menu.claudeAccount")
        }
    }

    /// Reads the checked entry's tag rather than the saved email, which may
    /// differ from cswap's in case.
    private func selection(_ entries: [ClaudeAccountMenu.Entry]) -> Binding<String?> {
        Binding(
            get: { entries.first(where: \.isChecked)?.account },
            set: { viewModel.pins.setClaudeAccount(pin.id, to: $0) }
        )
    }
}
