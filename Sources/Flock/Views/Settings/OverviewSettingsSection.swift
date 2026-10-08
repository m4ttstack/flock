import FlockCore
import SwiftUI

/// How Overview's cards read, and where Overview picks up when you come back.
struct OverviewSettingsSection: View {
    let bottomLineStore: MissionBottomLineStore
    let returnStore: OverviewReturnStore

    var body: some View {
        Section("Overview") {
            Picker(selection: Binding(get: { bottomLineStore.active }, set: { bottomLineStore.select($0) })) {
                ForEach(MissionBottomLine.allCases, id: \.self) { value in
                    Text(value.displayName).tag(value)
                }
            } label: {
                Text("Card detail")
                Text("The line under each card's title. Branch leaves out the repo when it matches the workspace's name.")
            }
            .accessibilityIdentifier("flock.settings.bottomLine")
            Picker(selection: Binding(get: { returnStore.active }, set: { returnStore.select($0) })) {
                ForEach(OverviewReturn.allCases, id: \.self) { value in
                    Text(value.displayName).tag(value)
                }
            } label: {
                Text("Coming back shows")
                Text("If you leave Overview with a pane open, what you see when you return.")
            }
            .accessibilityIdentifier("flock.settings.overviewReturn")
        }
    }
}
