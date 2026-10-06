import FlockCore
import SwiftUI

/// How Overview's cards read, and when it folds a pane away.
struct OverviewSettingsSection: View {
    let bottomLineStore: MissionBottomLineStore
    let cutoffStore: DormantCutoffStore

    var body: some View {
        Section("Overview") {
            Picker(selection: Binding(get: { bottomLineStore.active }, set: { bottomLineStore.select($0) })) {
                ForEach(MissionBottomLine.allCases, id: \.self) { value in
                    Text(value.displayName).tag(value)
                }
            } label: {
                Text("Bottom line")
                Text("Branch drops the repo when it is the workspace's own. Repo and branch always shows both; Hidden shows neither.")
            }
            .accessibilityIdentifier("flock.settings.bottomLine")
            Picker(selection: Binding(get: { cutoffStore.active }, set: { cutoffStore.select($0) })) {
                ForEach(DormantCutoff.allCases, id: \.self) { cutoff in
                    Text(cutoff.displayName).tag(cutoff)
                }
            } label: {
                Text("Dormant after")
                Text("Overview folds away a pane whose status has not changed for this long.")
            }
            .accessibilityIdentifier("flock.settings.dormantCutoff")
        }
    }
}
