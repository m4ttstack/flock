import Observation

/// Lets chrome outside the Settings window (the herdr update pill, the
/// Profile menu) pick the tab Settings opens on.
@MainActor
@Observable
final class SettingsTabSelection {
    var tab: SettingsTab
    var opensNewProfile = false
    init(tab: SettingsTab = .general) { self.tab = tab }
}
