import FlockCore
import SwiftUI

/// Whether and how long the dock shows agents that finished or need input.
/// The secondary line says what the choice does not cover, because a
/// question staying put under "For 5 seconds" would otherwise read as the
/// setting not working.
struct NotificationSettingsSection: View {
    let store: NotificationLifetimeStore

    var body: some View {
        Section("Notifications") {
            Picker(selection: Binding(get: { store.active }, set: { store.select($0) })) {
                ForEach(NotificationLifetime.allCases, id: \.self) { lifetime in
                    Text(lifetime.displayName).tag(lifetime)
                }
            } label: {
                Text("Show in sidebar")
                Text("When an agent finishes or needs your input. A question stays until you answer it.")
            }
            .accessibilityIdentifier("flock.settings.notificationLifetime")
        }
    }
}
