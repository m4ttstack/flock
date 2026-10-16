import AppKit
import FlockCore
import SwiftUI

/// Above the mouse patch row on the herdr tab. The warning leads with what
/// breaks; the plain note leads with what is available.
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
                    if !notice.isWarning, let detail = HerdrUpdateCopy.detail(notice) {
                        Text(detail).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
            .accessibilityIdentifier(notice.isWarning ? "flock.settings.herdrUpdate.warning" : "flock.settings.herdrUpdate.note")
        }
    }
}
