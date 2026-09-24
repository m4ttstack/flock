import FlockCore
import SwiftUI

/// What rearrange mode (Cmd+R) does after a drag lands. The secondary line
/// says what does not count as a move, because a missed drop that left the
/// mode on would otherwise read as the setting not working.
struct RearrangeSettingsSection: View {
    let store: RearrangeAfterMoveStore

    var body: some View {
        Section("Rearrange Mode") {
            Picker(selection: Binding(get: { store.active }, set: { store.select($0) })) {
                ForEach(RearrangeAfterMove.allCases, id: \.self) { value in
                    Text(value.displayName).tag(value)
                }
            } label: {
                Text("After a move")
                Text("A cancelled drag keeps the mode on. Esc always exits.")
            }
            .accessibilityIdentifier("flock.settings.rearrangeAfterMove")
        }
    }
}
