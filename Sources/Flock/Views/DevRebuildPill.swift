import FlockCore
import SwiftUI

/// What the title bar's restart slot shows while Rebuild Flock Dev runs, and
/// after it fails. A success needs nothing here: the new bundle lands and the
/// slot turns into the restart offer.
struct DevRebuildPill: View {
    let theme: Theme
    let state: DevRebuild.State
    let openLog: () -> Void

    var body: some View {
        switch state {
        case .idle:
            EmptyView()
        case .building(let started, let expected):
            TimelineView(.periodic(from: started, by: 0.5)) { context in
                let elapsed = context.date.timeIntervalSince(started)
                building(progress: DevRebuildPlan.progress(elapsed: elapsed, expected: expected))
            }
        case .failed:
            failed
        }
    }

    private func building(progress: Double) -> some View {
        label(glyph: "hammer.fill", text: "Building Flock Dev")
            .foregroundStyle(theme.textStrong)
            .background {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(theme.yellow.opacity(ChromeMetrics.TitleBar.rebuildTrackOpacity))
                        Rectangle().fill(theme.yellow.opacity(ChromeMetrics.TitleBar.rebuildFillOpacity))
                            .frame(width: geometry.size.width * progress)
                    }
                    .clipShape(Capsule())
                }
            }
            .animation(.linear(duration: 0.5), value: progress)
            .help("Rebuilding Flock Dev from main; the restart offer appears here when it lands")
            .accessibilityIdentifier("flock.titleBar.devRebuilding")
    }

    private var failed: some View {
        Button(action: openLog) {
            label(glyph: "exclamationmark.triangle.fill", text: "Build failed · Log")
                .foregroundStyle(theme.chrome)
                .background(theme.red, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background(WindowDragExclusion())
        .help("Open the rebuild's log")
        .accessibilityIdentifier("flock.titleBar.devRebuildFailed")
    }

    private func label(glyph: String, text: String) -> some View {
        HStack(spacing: ChromeMetrics.TitleBar.restartGlyphSpacing) {
            Image(systemName: glyph)
                .font(ChromeType.restartGlyph)
            Text(text)
                .font(ChromeType.restartLabel)
        }
        .padding(.horizontal, ChromeMetrics.TitleBar.restartHorizontalPadding)
        .padding(.vertical, ChromeMetrics.TitleBar.restartVerticalPadding)
    }
}
