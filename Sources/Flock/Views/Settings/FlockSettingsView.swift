import FlockCore
import SwiftUI

/// flock's Settings window (Cmd-,), in the system's own settings chrome
/// rather than the app's. A settings window is one of the few surfaces a
/// macOS user expects to look like every other app's, so this takes `Form`'s
/// grouped style and the system appearance and none of flock's theme: a dark
/// card floating in an oversized window read as a dialog that had escaped
/// from somewhere else.
///
/// Each setting is its own `Section`, never folded into another's.
struct FlockSettingsView: View {
    let herdrMousePatchStore: HerdrMousePatchStore
    let notificationLifetimeStore: NotificationLifetimeStore
    let rearrangeAfterMoveStore: RearrangeAfterMoveStore

    var body: some View {
        Form {
            NotificationSettingsSection(store: notificationLifetimeStore)
            RearrangeSettingsSection(store: rearrangeAfterMoveStore)
            HerdrMousePatchRow(store: herdrMousePatchStore)
        }
        .formStyle(.grouped)
        // The width system settings panes settle near. Height is left to the
        // content, which is what lets one section size like one section
        // rather than reserving room it is not using.
        .frame(width: 500)
        .onAppear { herdrMousePatchStore.refresh() }
    }
}
