import FlockCore
import SwiftUI

/// What a top-bar workspace's cell in the title bar shows. The secondary line
/// says names give way all at once, so a bar showing icons alone under
/// "Icon and name" does not read as the setting being ignored.
struct TopBarSettingsSection: View {
    let store: TopBarLabelStore

    var body: some View {
        Section("Title Bar Workspaces") {
            Picker(selection: Binding(get: { store.label }, set: { store.select($0) })) {
                ForEach(TopBarLabel.allCases, id: \.self) { Text($0.displayName).tag($0) }
            } label: {
                Text("Show")
                Text("When names do not fit beside the view tabs, every workspace shows its icon alone.")
            }
            .pickerStyle(.radioGroup)
            .accessibilityIdentifier("flock.settings.topBarLabel")
        }
    }
}
