import FlockCore
import SwiftUI

struct ProfileMenuRow: Equatable {
    let id: String
    let title: String
    let isCurrent: Bool
}

/// Flock > Profile: switch profiles, or open the Profiles tab of Settings.
struct ProfileCommands: Commands {
    let profiles: ProfileStore
    let isLocked: Bool
    let switchProfile: (String) async -> Bool
    let selection: SettingsTabSelection

    static func rows(profiles: [FlockProfile], currentID: String) -> [ProfileMenuRow] {
        profiles.map { ProfileMenuRow(id: $0.id, title: $0.name, isCurrent: $0.id == currentID) }
    }

    var body: some Commands {
        CommandGroup(after: .appSettings) {
            ProfileMenu(profiles: profiles, isLocked: isLocked, switchProfile: switchProfile, selection: selection)
        }
    }
}

/// A view rather than inline commands, because `openSettings` is only
/// reachable from a view's environment.
private struct ProfileMenu: View {
    let profiles: ProfileStore
    let isLocked: Bool
    let switchProfile: (String) async -> Bool
    let selection: SettingsTabSelection

    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Menu("Profile") {
            ForEach(ProfileCommands.rows(profiles: profiles.profiles, currentID: profiles.currentID), id: \.id) { row in
                Toggle(row.title, isOn: Binding(
                    get: { row.isCurrent },
                    set: { _ in
                        guard !row.isCurrent else { return }
                        Task { _ = await switchProfile(row.id) }
                    }
                ))
                .disabled(isLocked)
            }
            Divider()
            Button("New Profile…") { manage(opensNewProfile: true) }
                .disabled(isLocked)
                .accessibilityIdentifier("flock.profile.new")
            Button("Manage Profiles…") { manage(opensNewProfile: false) }
                .disabled(isLocked)
                .accessibilityIdentifier("flock.profile.manage")
        }
        .accessibilityIdentifier("flock.profile.menu")
    }

    private func manage(opensNewProfile: Bool) {
        selection.tab = .profiles
        if opensNewProfile { selection.opensNewProfile = true }
        openSettings()
    }
}
