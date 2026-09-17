import SwiftUI

/// View menu picker listing every built-in theme by display name, with a
/// checkmark on the active one.
struct ThemeMenu: View {
    let themeStore: ThemeStore

    var body: some View {
        Menu("Theme") {
            ForEach(Theme.builtins) { theme in
                Button {
                    themeStore.select(theme)
                } label: {
                    if theme.id == themeStore.active.id {
                        Label(theme.displayName, systemImage: "checkmark")
                    } else {
                        Text(theme.displayName)
                    }
                }
            }
        }
    }
}
