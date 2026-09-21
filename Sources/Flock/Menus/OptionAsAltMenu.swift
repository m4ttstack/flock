import FlockCore
import SwiftUI

/// View menu picker for the four Option-as-Alt values by display name, with a
/// checkmark on the active one.
struct OptionAsAltMenu: View {
    let store: OptionAsAltStore

    var body: some View {
        Menu("Option as Alt") {
            ForEach(OptionAsAlt.allCases, id: \.self) { value in
                Button {
                    store.select(value)
                } label: {
                    if value == store.active {
                        Label(value.displayName, systemImage: "checkmark")
                    } else {
                        Text(value.displayName)
                    }
                }
            }
        }
    }
}
