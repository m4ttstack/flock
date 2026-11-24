import FlockCore
import SwiftUI

struct HerdrUpdatePill: View {
    let theme: Theme
    let newest: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: ChromeMetrics.TitleBar.restartGlyphSpacing) {
                Image(systemName: "arrow.up")
                    .font(ChromeType.restartGlyph)
                Text(HerdrBuildCopy.pillTitle(newest: newest))
                    .font(ChromeType.restartLabel)
            }
            .foregroundStyle(theme.textStrong)
            .padding(.horizontal, ChromeMetrics.TitleBar.restartHorizontalPadding)
            .padding(.vertical, ChromeMetrics.TitleBar.restartVerticalPadding)
            .background(theme.surface1, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background(WindowDragExclusion())
        .help(HerdrBuildCopy.pillHelp)
        .accessibilityIdentifier("flock.titleBar.herdrUpdate")
    }
}
