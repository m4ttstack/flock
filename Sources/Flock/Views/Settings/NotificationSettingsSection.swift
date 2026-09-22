import FlockCore
import SwiftUI

/// How long the dock's attention cards stay. The secondary line says what
/// the choice does not cover, because a "needs input" card staying put under
/// "Hide after 5 seconds" would otherwise read as the setting not working.
struct NotificationSettingsSection: View {
    let store: NotificationLifetimeStore

    var body: some View {
        Section("Notifications") {
            Picker(selection: Binding(get: { store.active }, set: { store.select($0) })) {
                ForEach(NotificationLifetime.allCases, id: \.self) { lifetime in
                    Text(lifetime.displayName).tag(lifetime)
                }
            } label: {
                Text("Finished agents")
                Text("Cards for agents that need input stay until you answer.")
            }
            .accessibilityIdentifier("flock.settings.notificationLifetime")
        }
    }
}
