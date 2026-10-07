import FlockCore
import SwiftUI

/// How Overview's cards read.
struct OverviewSettingsSection: View {
    let bottomLineStore: MissionBottomLineStore

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
        }
    }
}
