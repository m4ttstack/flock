import FlockCore
import SwiftUI

/// The one row flock's settings show about herdr's mouse support: whichever
/// of the four states `HerdrMousePatchDecision` found, its explanation, and
/// the single action (if any) that state offers. Install and Revert both
/// gate behind the same confirmation dialog, driven by the store rather than
/// local view state, so the exact path being replaced is always named.
struct HerdrMousePatchRow: View {
    let theme: Theme
    let store: HerdrMousePatchStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(HerdrMousePatchCopy.heading)
                    .font(.headline)
                    .foregroundStyle(theme.textLabel)
                Spacer(minLength: 12)
                actionButton
            }
            Text(bodyText)
                .font(.system(size: 12))
                .foregroundStyle(theme.subtext0)
                .fixedSize(horizontal: false, vertical: true)
            if let message = store.lastErrorMessage {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.red)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.surface1))
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
            return "herdr was not found on this Mac, so there is nothing to check."
        }
        return HerdrMousePatchCopy.body(for: state)
    }
}
