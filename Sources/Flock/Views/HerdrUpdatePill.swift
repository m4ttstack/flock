import FlockCore
import SwiftUI

struct HerdrUpdatePill: View {
    let theme: Theme
    let notice: HerdrUpdateNotice
    var updating = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: ChromeMetrics.TitleBar.restartGlyphSpacing) {
                Image(systemName: glyph)
                    .font(ChromeType.restartGlyph)
                Text(updating ? HerdrUpdateRun.pillTitle : HerdrUpdateCopy.pillTitle(notice))
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
        .help(help)
        .accessibilityIdentifier(
            updating ? "flock.titleBar.herdrUpdate.updating"
                : notice.isWarning ? "flock.titleBar.herdrUpdate.warning" : "flock.titleBar.herdrUpdate"
        )
    }

    private var glyph: String {
        if updating { return "arrow.triangle.2.circlepath" }
        return notice.isWarning ? "exclamationmark.triangle.fill" : "arrow.up"
    }

    private var help: String {
        if updating { return "flock is updating herdr" }
        return notice.isWarning ? HerdrUpdateCopy.headline(notice) : "A newer herdr is available. Open Settings to update."
    }
}
