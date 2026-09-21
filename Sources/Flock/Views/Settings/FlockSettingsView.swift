import SwiftUI

/// flock's Settings window (Cmd-,). The herdr heading and its one row are the
/// whole contents today; a later setting gets its own heading beside it
/// rather than folding into this one.
struct FlockSettingsView: View {
    let theme: Theme
    let herdrMousePatchStore: HerdrMousePatchStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("herdr")
                .font(.title3)
                .foregroundStyle(theme.textStrong)
            HerdrMousePatchRow(theme: theme, store: herdrMousePatchStore)
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 420, minHeight: 160, alignment: .top)
        .background(theme.canvas)
        .onAppear { herdrMousePatchStore.refresh() }
    }
}
