import Observation

/// Lets chrome outside the Settings window (the herdr update pill) pick the
/// tab Settings opens on.
@MainActor
@Observable
final class SettingsTabSelection {
    var tab: SettingsTab
    init(tab: SettingsTab = .general) { self.tab = tab }
}
