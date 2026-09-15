import PaddockCore
import SwiftUI

/// The floating proxy: the dragged item's own footprint at one scale, carrying
/// its name. No tilt -- pane cells are content surfaces, and a tilted terminal
/// reads as a glitch.
struct GhostOverlay: View {
    let theme: Theme
    let ghost: DragCoordinator.Ghost
    /// True while the settle spring carries the ghost onto its landing rect.
    /// A pane drop lands on a pane box, so the ghost's own border would sit
    /// just inside that pane's border for the whole spring.
    var settling = false

    var body: some View {
        let size = DragVisuals.ghostSize(forOrigin: ghost.originSize, bounds: ghost.bounds)
        let compact = ghost.isCompact
        let labelled = carriesLabel(width: size.width)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: compact ? ChromeMetrics.Ghost.compactSpacing : ChromeMetrics.Ghost.spacing) {
                Image(systemName: ghost.symbol)
                    .font(compact ? ChromeType.ghostCompactSymbol : ChromeType.ghostSymbol)
                if labelled {
                    Text(ghost.title)
                        .font(compact ? ChromeType.ghostCompactLabel : ChromeType.ghostLabel)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(theme.textStrong)
            .frame(maxWidth: .infinity, alignment: labelled ? .leading : .center)
            if !compact {
                Spacer(minLength: 0)
            }
        }
        .padding(compact ? ChromeMetrics.Ghost.compactPadding : ChromeMetrics.Ghost.padding)
        .frame(width: size.width, height: size.height, alignment: compact ? .leading : .topLeading)
        // Translucent so the tab or row under the pointer stays readable
        // through the proxy while it is being targeted.
        .background(theme.chrome.opacity(0.7), in: RoundedRectangle(cornerRadius: PaneChrome.cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: PaneChrome.cornerRadius)
                .strokeBorder(theme.accent, lineWidth: 1)
                .opacity(settling ? 0 : 1)
        )
        .shadow(color: theme.chrome.opacity(0.5), radius: ChromeMetrics.Ghost.shadowRadius, y: ChromeMetrics.Ghost.shadowY)
    }

    /// A proxy sized from a narrow mini pane has no room for a title, and it
    /// is the item's footprint that decides the box, never the label.
    private func carriesLabel(width: CGFloat) -> Bool {
        !ghost.isCompact || width >= ChromeMetrics.Ghost.compactLabelMinimumWidth
    }
}
