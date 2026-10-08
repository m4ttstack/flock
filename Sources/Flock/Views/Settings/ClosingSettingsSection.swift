import FlockCore
import SwiftUI

/// Whether a close that ends an agent session asks first (`AgentSessions`).
/// The close prompt's "Don't warn me next time" turns this off, so this is
/// where it comes back on.
struct ClosingSettingsSection: View {
    let store: AgentCloseWarningStore

    var body: some View {
        Section("Closing") {
            Toggle(isOn: Binding(get: { store.active }, set: { store.select($0) })) {
                Text("Warn before closing an agent")
                Text(
                    "Asks before a tab or pane running Claude Code, Codex or another agent closes. "
                        + "A busy pane or a workspace's last tab asks either way."
                )
            }
            .toggleStyle(.switch)
            .accessibilityIdentifier("flock.settings.agentCloseWarning")
        }
    }
}
