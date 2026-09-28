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
    let rtModalTextSizeStore: RtModalTextSizeStore

    var body: some View {
        Form {
            NotificationSettingsSection(store: notificationLifetimeStore)
            RearrangeSettingsSection(store: rearrangeAfterMoveStore)
            RtModalTextSizeSection(store: rtModalTextSizeStore)
            HerdrMousePatchRow(store: herdrMousePatchStore)
        }
        .formStyle(.grouped)
        // The width system settings panes settle near; the height follows
        // the window, which `SettingsWindowSizer` makes resizable.
        .frame(width: SettingsWindowSizer.width)
        .frame(minHeight: SettingsWindowSizer.minHeight, maxHeight: .infinity)
        .background(SettingsWindowSizer())
        .onAppear { herdrMousePatchStore.refresh() }
    }
}
