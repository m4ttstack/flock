import FlockCore
import SwiftUI

/// View menu picker for the four scroll speeds by display name, with a
/// checkmark on the active one.
struct ScrollSpeedMenu: View {
    let store: ScrollSpeedStore

    var body: some View {
        Menu("Scroll Speed") {
            ForEach(ScrollSpeed.allCases, id: \.self) { speed in
                Button {
                    store.select(speed)
                } label: {
                    if speed == store.active {
                        Label(speed.displayName, systemImage: "checkmark")
                    } else {
                        Text(speed.displayName)
                    }
                }
            }
        }
    }
}
