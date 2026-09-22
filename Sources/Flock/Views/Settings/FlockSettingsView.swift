import SwiftUI

/// flock's Settings window (Cmd-,), in the system's own settings chrome
/// rather than the app's. A settings window is one of the few surfaces a
/// macOS user expects to look like every other app's, so this takes `Form`'s
/// grouped style and the system appearance and none of flock's theme: a dark
/// card floating in an oversized window read as a dialog that had escaped
/// from somewhere else.
///
/// The herdr section and its one row are the whole contents today; a later
/// setting gets its own `Section` beside it rather than folding into this one.
struct FlockSettingsView: View {
    let herdrMousePatchStore: HerdrMousePatchStore

    var body: some View {
        Form {
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
