import FlockCore
import SwiftUI

/// The one row flock's settings show about herdr's mouse support: whichever
/// of the six states `HerdrMousePatchDecision` found, its explanation, and
/// the single action (if any) that state offers. Install and Restore both gate
/// behind the same confirmation dialog, driven by the store rather than local
/// view state, so the exact path being replaced is always named.
///
/// Built from `Section` and `LabeledContent` so it inherits the system's
/// settings appearance instead of painting its own card. The explanation runs
/// long by design (it names the binary being replaced), so it is the label's
/// secondary line, which is where macOS puts exactly that kind of text.
struct HerdrMousePatchRow: View {
    let store: HerdrMousePatchStore

    var body: some View {
        Section(HerdrMousePatchCopy.heading) {
            LabeledContent {
                actionButton
            } label: {
                Text(HerdrMousePatchCopy.rowTitle)
                Text(bodyText)
            }
            if let message = store.lastErrorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("flock.settings.herdrMousePatch.error")
            }
        }
        .confirmationDialog(
            store.pendingConfirmation?.confirmation.title ?? "",
            isPresented: Binding(
                get: { store.pendingConfirmation != nil },
                set: { shown in if !shown { store.cancelPendingConfirmation() } }
            ),
            titleVisibility: .visible,
            presenting: store.pendingConfirmation
        ) { pending in
            Button(pending.confirmation.confirmButtonTitle) {
                store.confirmPendingAction()
            }
            .accessibilityIdentifier("flock.settings.herdrMousePatch.confirm")
            Button("Cancel", role: .cancel) { store.cancelPendingConfirmation() }
                .accessibilityIdentifier("flock.settings.herdrMousePatch.cancel")
        } message: { pending in
            Text(pending.confirmation.message)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if let state = store.state, let title = HerdrMousePatchCopy.actionTitle(for: state) {
            Button(title) {
                switch state {
                case .patchable: store.requestInstall()
                case .installed: store.requestRevert()
                case .supportedByHerdr, .artifactUnavailable, .notWritable, .unsupportedVersion: break
                }
            }
            .accessibilityIdentifier("flock.settings.herdrMousePatch.action")
        }
    }

    private var bodyText: String {
        guard let state = store.state else {
            return "Not available. flock can't find herdr on this Mac."
        }
        return HerdrMousePatchCopy.body(for: state)
    }
}
