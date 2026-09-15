import PaddockCore
import SwiftUI

/// The floating proxy: the dragged item's own footprint, scaled down far
/// enough to see the drop target under it, carrying its name. No tilt -- pane
/// cells are content surfaces, and a tilted terminal reads as a glitch.
struct GhostOverlay: View {
    let theme: Theme
    let ghost: DragCoordinator.Ghost
    /// True while the settle spring carries the ghost onto its landing rect.
    /// A pane drop lands on a pane box, so the ghost's own border would sit
    /// just inside that pane's border for the whole spring.
    var settling = false

    /// Floors for a proxy whose origin is tiny (a tab, a rail row), so
    /// the label always has somewhere to sit.
    private static let minimumSize = CGSize(width: 150, height: 32)

    var body: some View {
        let size = DragVisuals.ghostSize(forOrigin: ghost.originSize)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: ghost.symbol)
                    .font(.system(size: 11, weight: .semibold))
                Text(ghost.title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(theme.textStrong)
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(
            width: max(size.width, Self.minimumSize.width),
            height: max(size.height, Self.minimumSize.height),
            alignment: .topLeading
        )
        // Translucent so the tab or row under the pointer stays readable
        // through the proxy while it is being targeted.
        .background(theme.chrome.opacity(0.7), in: RoundedRectangle(cornerRadius: PaneCellView.cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: PaneCellView.cornerRadius)
                .strokeBorder(theme.accent, lineWidth: 1)
                .opacity(settling ? 0 : 1)
        )
        .shadow(color: theme.chrome.opacity(0.5), radius: 14, y: 8)
    }
}
