import FlockCore
import SwiftUI

/// The version of herdr flock is connected to, then the one row flock's
/// settings show about the mattstack build: whichever of the states
/// `HerdrBuildDecision` found, its explanation, and the one action (if any)
/// that state offers. Replacing an existing herdr gates behind a
/// confirmation dialog, driven by the store rather than local view state, so
/// the exact path being replaced is always named.
///
/// Built from `Section` and `LabeledContent` so it inherits the system's
/// settings appearance instead of painting its own card. The explanation is
/// the label's secondary line, which is where macOS puts that kind of text.
struct HerdrBuildRow: View {
    let store: HerdrBuildStore
    /// nil while flock is not connected to herdr.
    var herdrVersion: String? = nil

    var body: some View {
        Section(HerdrBuildCopy.heading) {
            LabeledContent("Version") {
                Text(herdrVersion.map { "v\($0)" } ?? "Not connected")
                    .textSelection(.enabled)
            }
            .accessibilityIdentifier("flock.settings.herdrVersion")
            LabeledContent {
                actionButton
            } label: {
                Text(HerdrBuildCopy.rowTitle)
                if let state = store.state {
                    Text(HerdrBuildCopy.body(for: state))
                        .accessibilityIdentifier("flock.settings.herdrBuild.body")
                }
            }
            if let reason = store.restartPrompt {
                let restartsServer = store.needsServerRestart
                LabeledContent {
                    if store.serverRestarting {
                        ProgressView().controlSize(.small)
                            .accessibilityIdentifier("flock.settings.herdrBuild.restarting")
                    } else {
                        Button(HerdrBuildCopy.restartActionTitle(restartsServer: restartsServer)) {
                            if restartsServer {
                                store.requestServerRestart(source: .settings)
                            } else {
                                AppRelaunch.relaunch()
                            }
                        }
                        .accessibilityIdentifier("flock.settings.herdrBuild.restart")
                    }
                } label: {
                    Text(HerdrBuildCopy.restartHeadline(for: reason))
                    Text(HerdrBuildCopy.restartDetail(for: reason, restartsServer: restartsServer))
                }
            }
            if let message = store.serverRestartError {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("flock.settings.herdrBuild.restartError")
            }
            if let message = store.lastErrorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("flock.settings.herdrBuild.error")
            }
        }
        .confirmationDialog(
            ownConfirmation?.confirmation.title ?? "",
            isPresented: Binding(
                get: { ownConfirmation != nil },
                set: { shown in if !shown { store.cancelPendingConfirmation() } }
            ),
            titleVisibility: .visible,
            presenting: ownConfirmation
        ) { pending in
            Button(pending.confirmation.confirmButtonTitle) {
                store.confirmPendingAction()
            }
            .accessibilityIdentifier("flock.settings.herdrBuild.confirm")
            Button("Cancel", role: .cancel) { store.cancelPendingConfirmation() }
                .accessibilityIdentifier("flock.settings.herdrBuild.cancel")
        } message: { pending in
            Text(pending.confirmation.message)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch store.phase {
        case .downloading(let fraction):
            ProgressView(value: fraction) { Text("Downloading...") }
                .frame(width: 120)
                .accessibilityIdentifier("flock.settings.herdrBuild.progress")
        case .installing:
            ProgressView().controlSize(.small)
        case .idle:
            if let state = store.state, let title = HerdrBuildCopy.actionTitle(for: state) {
                Button(title) {
                    // Nothing on disk to replace, so nothing to confirm.
                    if case .missing = state {
                        store.installMissing(source: .settings)
                    } else {
                        store.requestInstall(source: .settings)
                    }
                }
                .disabled(store.serverRestarting)
                .accessibilityIdentifier("flock.settings.herdrBuild.action")
            }
        }
    }

    /// The main window's banner presents its own requests.
    private var ownConfirmation: HerdrBuildStore.PendingConfirmation? {
        store.pendingConfirmation.flatMap { $0.source == .settings ? $0 : nil }
    }
}
