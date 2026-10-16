import AppKit
import FlockCore
import SwiftUI

/// Above the mouse patch row on the herdr tab. The warning leads with what
/// breaks; the plain note leads with what is available. The command stays
/// beside the button as a fallback, and is all a Homebrew install gets.
struct HerdrUpdateSection: View {
    let store: HerdrUpdateStore

    var body: some View {
        if let notice = store.notice {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label {
                        Text(HerdrUpdateCopy.headline(notice)).fontWeight(.semibold)
                    } icon: {
                        Image(systemName: notice.isWarning ? "exclamationmark.triangle.fill" : "arrow.up.circle")
                            .foregroundStyle(notice.isWarning ? Color.orange : Color.accentColor)
                    }
                    if notice.isWarning, let detail = HerdrUpdateCopy.detail(notice) {
                        Text(detail).foregroundStyle(.secondary)
                    }
                    Text(notice.isWarning ? HerdrUpdateCopy.warningLead : HerdrUpdateCopy.handoffLead)
                        .foregroundStyle(.secondary)
                    if store.canRunUpdate {
                        updateControl(warning: notice.isWarning)
                            .frame(minHeight: 24, alignment: .leading)
                    }
                    HStack {
                        Text(notice.command)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(notice.command, forType: .string)
                        }
                        .accessibilityIdentifier("flock.settings.herdrUpdate.copy")
                    }
                    if let error = store.updateError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("flock.settings.herdrUpdate.error")
                    }
                    if !notice.isWarning, let detail = HerdrUpdateCopy.detail(notice) {
                        Text(detail).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
            .accessibilityIdentifier(notice.isWarning ? "flock.settings.herdrUpdate.warning" : "flock.settings.herdrUpdate.note")
            .confirmationDialog(
                store.pendingUpdate?.title ?? "",
                isPresented: Binding(
                    get: { store.pendingUpdate != nil },
                    set: { shown in if !shown { store.cancelUpdate() } }
                ),
                titleVisibility: .visible,
                presenting: store.pendingUpdate
            ) { confirmation in
                Button(confirmation.confirmButtonTitle) { store.confirmUpdate() }
                    .accessibilityIdentifier("flock.settings.herdrUpdate.confirm")
                Button("Cancel", role: .cancel) { store.cancelUpdate() }
                    .accessibilityIdentifier("flock.settings.herdrUpdate.cancel")
            } message: { confirmation in
                Text(confirmation.message)
            }
        }
    }

    @ViewBuilder
    private func updateControl(warning: Bool) -> some View {
        switch store.updatePhase {
        case .idle:
            Button(HerdrUpdateRun.buttonTitle) { store.requestUpdate() }
                .buttonStyle(.borderedProminent)
                .tint(warning ? .orange : .accentColor)
                .disabled(store.isBlockedByPatchInstall)
                .accessibilityIdentifier("flock.settings.herdrUpdate.run")
        case .updating:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(HerdrUpdateRun.progressTitle).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("flock.settings.herdrUpdate.progress")
        }
    }
}
