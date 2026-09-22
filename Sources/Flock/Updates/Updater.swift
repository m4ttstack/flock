#if FLOCK_SPARKLE
import Foundation
import Observation
import Sparkle
import SwiftUI

/// Sparkle's standard updater and UI, started at launch.
///
/// Compiled only into the Release configuration of the Flock target (see
/// `FLOCK_SPARKLE` in project.yml): Sparkle replaces the running app at its
/// own path, so a Debug or Flock-dev build that checked for updates would
/// swap itself for the latest release.
@MainActor
@Observable
final class Updater {
    private(set) var canCheckForUpdates = false

    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var observation: NSKeyValueObservation?

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
        )
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
            guard let canCheck = change.newValue else { return }
            Task { @MainActor in self?.canCheckForUpdates = canCheck }
        }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

struct CheckForUpdatesCommands: Commands {
    let updater: Updater

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            CheckForUpdatesButton(updater: updater)
        }
    }
}

/// A view rather than a bare `Button` in the command group, so observation
/// tracks `canCheckForUpdates` and the item re-enables when a check ends.
private struct CheckForUpdatesButton: View {
    let updater: Updater

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
            .accessibilityIdentifier("flock.app.checkForUpdates")
    }
}
#endif
