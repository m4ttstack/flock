import FlockCore
import SwiftUI

/// ⌃`'s profiles, over the whole window below the title bar: a switch
/// replaces everything the window shows, and the switch loader has no tab
/// area to sit over.
struct ProfileSwitcherOverlay: View {
    let theme: Theme
    let switcher: ProfileSwitcher
    let profiles: ProfileStore
    let isLocked: Bool
    let currentDot: ProfileConnectionDot?
    let blocked: () -> Bool
    let choose: (String) -> Void

    var body: some View {
        SwitcherView(
            theme: theme, switcher: switcher, trigger: .controlBacktick, accessibilityPrefix: "flock.profileSwitcher",
            heading: "Profiles",
            row: { [profiles, currentDot] id in Self.row(id, profiles: profiles, currentDot: currentDot) },
            candidates: { [profiles, isLocked] in ProfileSwitcher.candidates(profiles.profiles, isLocked: isLocked) },
            current: { [profiles] in ProfileID(rawValue: profiles.currentID) },
            blocked: blocked,
            go: { choose($0.rawValue) }
        )
        .padding(.top, ChromeMetrics.TitleBar.height)
    }

    /// The picker's row for the profile, so the marker and the current
    /// machine's dot follow the picker's rule.
    static func row(_ id: ProfileID, profiles: ProfileStore, currentDot: ProfileConnectionDot?) -> SwitcherRow? {
        ProfilePickerModel(profiles: profiles.profiles, currentID: profiles.currentID, currentDot: currentDot)
            .rows.first { $0.id == id.rawValue }
            .map(SwitcherRow.profile)
    }
}

extension SwitcherBlockers {
    /// What the window-wide switchers, ⌃`'s profiles and ⌥`'s servers, read
    /// as their key lands.
    @MainActor
    static func window(session: FlockSession, profilePicker: ProfilePickerContext, profiles: ProfileSwitcher) -> SwitcherBlockers {
        SwitcherBlockers(
            paletteOpen: session.commandPalette.isOpen, renaming: session.viewModel.renameEditorIsOnScreen,
            rtModal: session.viewModel.rt.modal != nil, profilePickerOpen: profilePicker.isOpen,
            active: SwitcherKind.active(
                workspaces: session.workspaceSwitcher, tabs: session.tabSwitcher, profiles: profiles,
                servers: session.serverSwitcher, agents: session.agentSwitcher
            )
        )
    }
}
