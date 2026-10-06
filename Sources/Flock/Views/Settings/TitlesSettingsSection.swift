import FlockCore
import SwiftUI

/// Whether a pane alone in its tab is named by the tab (`PaneNaming`). The
/// secondary line says herdr is untouched, because a pane name vanishing
/// from flock would otherwise read as the name being lost.
struct TitlesSettingsSection: View {
    let store: OneTitleStore

    var body: some View {
        Section("Titles") {
            Toggle(isOn: Binding(get: { store.active }, set: { store.select($0) })) {
                Text("One title for a one-pane tab")
                Text(
                    "A tab holding one pane shows one title everywhere: the tab's name, or the pane's when the tab has none. "
                        + "A second pane brings each pane's own title back. herdr's names are not changed."
                )
            }
            .toggleStyle(.switch)
            .accessibilityIdentifier("flock.settings.oneTitle")
        }
    }
}
