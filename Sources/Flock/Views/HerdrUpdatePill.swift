import FlockCore
import SwiftUI

struct HerdrUpdatePill: View {
    let theme: Theme
    let notice: HerdrUpdateNotice
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: ChromeMetrics.TitleBar.restartGlyphSpacing) {
                Image(systemName: notice.isWarning ? "exclamationmark.triangle.fill" : "arrow.up")
                    .font(ChromeType.restartGlyph)
                Text(HerdrUpdateCopy.pillTitle(notice))
                    .font(ChromeType.restartLabel)
            }
            .foregroundStyle(notice.isWarning ? theme.chrome : theme.textStrong)
            .padding(.horizontal, ChromeMetrics.TitleBar.restartHorizontalPadding)
            .padding(.vertical, ChromeMetrics.TitleBar.restartVerticalPadding)
            .background(notice.isWarning ? theme.peach : theme.surface1, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background(WindowDragExclusion())
        .help(notice.isWarning ? HerdrUpdateCopy.headline(notice) : "A newer herdr is available. Open Settings to update.")
        .accessibilityIdentifier(notice.isWarning ? "flock.titleBar.herdrUpdate.warning" : "flock.titleBar.herdrUpdate")
    }
}
