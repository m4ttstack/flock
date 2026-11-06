import FlockCore
import SwiftUI

struct ProfileMenuRow: Equatable {
    let id: String
    let title: String
    let isCurrent: Bool
}

/// Flock > Profile: open the rail's picker, switch profiles, or open the
/// Profiles tab of Settings.
struct ProfileCommands: Commands {
    let picker: ProfilePickerContext
    let selection: SettingsTabSelection

    /// The picker's sections, each between rules: Default and the user's
    /// profiles, then the herdr machines. Empty sections are left out.
    static func sections(profiles: [FlockProfile], currentID: String) -> [[ProfileMenuRow]] {
        let model = ProfilePickerModel(profiles: profiles, currentID: currentID, currentDot: nil)
        return [model.local, model.machines]
            .filter { !$0.isEmpty }
            .map { section in section.map { ProfileMenuRow(id: $0.id, title: $0.title, isCurrent: $0.isCurrent) } }
    }

    var body: some Commands {
        CommandGroup(after: .appSettings) {
            ProfileMenu(picker: picker, selection: selection)
        }
    }
}

/// A view rather than inline commands, because `openSettings` is only
/// reachable from a view's environment.
private struct ProfileMenu: View {
    let picker: ProfilePickerContext
    let selection: SettingsTabSelection

    private var profiles: ProfileStore { picker.profiles }
    private var isLocked: Bool { picker.isLocked }

    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Menu("Profile") {
            Button("Switch Profile\u{2026}") { picker.open() }
                .keyboardShortcut(ProfilePickerContext.shortcut)
                .disabled(!picker.canOpen)
                .accessibilityIdentifier("flock.profile.switch")
            let sections = ProfileCommands.sections(profiles: profiles.profiles, currentID: profiles.currentID)
            ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                Divider()
                ForEach(section, id: \.id) { row in
                    Toggle(row.title, isOn: Binding(
                        get: { row.isCurrent },
                        set: { _ in picker.choose(row.id) }
                    ))
                    .disabled(isLocked)
                }
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
        picker.manage(opensNewProfile: opensNewProfile, selection: selection, openSettings: openSettings)
    }
}
