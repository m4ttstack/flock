import FlockCore
import SwiftUI

/// The link types the user told a pane's open prompt to stop asking about
/// (`LinkTrust`). The prompt only ever adds one, so this is where it comes
/// off again.
struct LinkTrustSettingsSection: View {
    let store: LinkTrustStore

    var body: some View {
        Section {
            if store.trust.listed.isEmpty {
                Text("None")
                    .foregroundStyle(.secondary)
            }
            ForEach(store.trust.listed, id: \.self) { scheme in
                LabeledContent("\(scheme)://") {
                    Button("Remove") { store.revoke(scheme) }
                        .accessibilityIdentifier("flock.settings.linkTrust.remove.\(scheme)")
                }
            }
        } header: {
            Text("Trusted Link Types")
        } footer: {
            Text("Links of these types open from a pane without asking. Web and mail links always do.")
        }
    }
}
