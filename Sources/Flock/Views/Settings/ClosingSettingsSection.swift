import FlockCore
import SwiftUI

/// Whether a close that ends an agent session asks first (`AgentSessions`),
/// for tabs and for panes apart. The close prompt's "Don't warn me next time"
/// turns one off, so this is where it comes back on.
struct ClosingSettingsSection: View {
    let store: AgentCloseWarningStore

    var body: some View {
        Section("Closing") {
            toggle(
                .tab, "Warn before closing a tab running an agent",
                "Claude Code, Codex or any other agent herdr detects, idle or not."
            )
            toggle(
                .pane, "Warn before closing a pane running an agent",
                "A busy pane or a workspace's last tab asks either way."
            )
        }
    }

    private func toggle(_ kind: AgentCloseWarningStore.Kind, _ title: String, _ detail: String) -> some View {
        Toggle(isOn: Binding(get: { store.warns(on: kind) }, set: { store.select($0, for: kind) })) {
            Text(title)
            Text(detail)
        }
        .toggleStyle(.switch)
        .accessibilityIdentifier("flock.settings.agentCloseWarning.\(kind.rawValue)")
    }
}
