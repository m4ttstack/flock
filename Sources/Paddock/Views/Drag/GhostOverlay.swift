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

    /// Floors for a proxy whose origin is tiny (a tab pill, a rail row), so
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
            .foregroundStyle(theme.chromeTextStrong)
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(
            width: max(size.width, Self.minimumSize.width),
            height: max(size.height, Self.minimumSize.height),
            alignment: .topLeading
        )
        .background(theme.paneHeaderBg, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(theme.accent, lineWidth: 2).opacity(settling ? 0 : 1))
        .shadow(color: theme.railBg.opacity(0.5), radius: 14, y: 8)
    }
}
