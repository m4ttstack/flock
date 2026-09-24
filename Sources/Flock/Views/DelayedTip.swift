import SwiftUI

/// A tooltip drawn in the view tree: `.help` cannot be delayed, and a system
/// tip never shows over a pane, whose terminal surface owns the pointer.
struct DelayedTipLabel: View {
    let theme: Theme
    let lines: [String]

    private typealias Metrics = ChromeMetrics.DelayedTip

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.lineSpacing) {
            ForEach(lines, id: \.self) { line in
                Text(line)
                    .font(ChromeType.delayedTip)
                    .foregroundStyle(theme.textStrong)
                    .fixedSize()
            }
        }
        .padding(.horizontal, Metrics.horizontalPadding)
        .padding(.vertical, Metrics.verticalPadding)
        .background(RoundedRectangle(cornerRadius: Metrics.cornerRadius).fill(Color(theme.palette.surface1)))
        .overlay(RoundedRectangle(cornerRadius: Metrics.cornerRadius).strokeBorder(Color(theme.palette.overlay0).opacity(0.5)))
        .shadow(color: .black.opacity(0.25), radius: Metrics.shadowRadius, y: 1)
        .allowsHitTesting(false)
    }
}

private struct DelayedTip: ViewModifier {
    let theme: Theme
    let lines: [String]
    @State private var isHovering = false
    @State private var isShown = false

    func body(content: Content) -> some View {
        content
            .onHover { isHovering = $0 }
            // Hangs below the control's trailing edge, so it opens into the
            // pane rather than past the window's right side.
            .overlay(alignment: .bottomTrailing) {
                if isShown {
                    DelayedTipLabel(theme: theme, lines: lines)
                        .alignmentGuide(.bottom) { $0[.top] - ChromeMetrics.DelayedTip.gap }
                        .transition(.opacity)
                }
            }
            .task(id: isHovering) {
                guard isHovering else {
                    isShown = false
                    return
                }
                try? await Task.sleep(for: ChromeMetrics.DelayedTip.delay)
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.12)) { isShown = true }
            }
    }
}

extension View {
    func delayedTip(_ theme: Theme, lines: [String]) -> some View {
        modifier(DelayedTip(theme: theme, lines: lines))
    }
}
