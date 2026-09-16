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
        content(size: size)
            .frame(width: size.width, height: size.height, alignment: ghost.isCompact ? .leading : .topLeading)
            // Translucent so the tab or row under the pointer stays readable
            // through the proxy while it is being targeted.
            .background(theme.chrome.opacity(DragVisuals.ghostOpacity), in: RoundedRectangle(cornerRadius: PaneChrome.cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: PaneChrome.cornerRadius)
                    .strokeBorder(theme.accent, lineWidth: 1)
                    .opacity(settling ? 0 : 1)
            )
            .shadow(color: theme.chrome.opacity(0.5), radius: ChromeMetrics.Ghost.shadowRadius, y: ChromeMetrics.Ghost.shadowY)
    }

    @ViewBuilder
    private func content(size: CGSize) -> some View {
        if let miniature = ghost.tabMiniature {
            self.miniature(miniature, size: size)
        } else {
            block(size: size)
        }
    }

    /// A whole tab is drawn as what it is: its handle strip over its own mini
    /// pane layout, in the roles the thumbnail uses, at the thumbnail's own
    /// size. A generic block would read as the wrong thing entirely, since
    /// the target it is aimed at is another tab's thumbnail.
    ///
    /// Held at the same opacity as any proxy's ground, and given no ground of
    /// its own: a tab proxy is exactly a thumbnail's size and centered on the
    /// pointer, so an opaque one would cover the thumbnail it is aimed at
    /// along with that thumbnail's drop wash. The clip belongs here rather
    /// than on the shared chain, where it would silently bound a block proxy
    /// nothing asked to clip.
    private func miniature(_ miniature: DragCoordinator.Ghost.TabMiniature, size: CGSize) -> some View {
        VStack(spacing: 0) {
            TabHandleStrip(
                theme: theme, title: miniature.title, status: miniature.status,
                isFocusedTab: miniature.isFocusedTab
            )
            ZStack(alignment: .topLeading) {
                ForEach(Array(miniature.panes.enumerated()), id: \.offset) { _, pane in
                    MiniPane(theme: theme, title: pane.title, status: pane.status)
                        .frame(width: pane.box.width, height: pane.box.height)
                        .offset(x: pane.box.minX, y: pane.box.minY)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: size.width, height: size.height)
        .opacity(DragVisuals.ghostOpacity)
        .clipShape(RoundedRectangle(cornerRadius: PaneChrome.cornerRadius))
    }

    private func block(size: CGSize) -> some View {
        let compact = ghost.isCompact
        let labelled = carriesLabel(width: size.width)
        return VStack(alignment: .leading, spacing: 0) {
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
    }

    /// A proxy sized from a narrow mini pane has no room for a title, and it
    /// is the item's footprint that decides the box, never the label.
    private func carriesLabel(width: CGFloat) -> Bool {
        !ghost.isCompact || width >= ChromeMetrics.Ghost.compactLabelMinimumWidth
    }
}
