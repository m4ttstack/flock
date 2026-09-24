import AppKit
import FlockCore
import SwiftUI

/// A pane's drag grip: two rows of three dots, like a braille cell on its
/// side, with an open hand and a soft pill under the pointer.
struct PaneGrip: View {
    let theme: Theme
    let dragInFlight: Bool

    @State private var isHovering = false

    private typealias Metrics = ChromeMetrics.Pane.Grip

    var body: some View {
        Canvas { context, size in
            let width = Metrics.dot * CGFloat(Metrics.columns) + Metrics.dotGap * CGFloat(Metrics.columns - 1)
            let height = Metrics.dot * CGFloat(Metrics.rows) + Metrics.dotGap * CGFloat(Metrics.rows - 1)
            let origin = CGPoint(x: (size.width - width) / 2, y: (size.height - height) / 2)
            for row in 0..<Metrics.rows {
                for column in 0..<Metrics.columns {
                    let dot = CGRect(
                        x: origin.x + CGFloat(column) * (Metrics.dot + Metrics.dotGap),
                        y: origin.y + CGFloat(row) * (Metrics.dot + Metrics.dotGap),
                        width: Metrics.dot, height: Metrics.dot
                    )
                    context.fill(Path(ellipseIn: dot), with: .color(isHovering ? theme.textDim : theme.overlay0))
                }
            }
        }
        .frame(width: Metrics.pillSize.width, height: Metrics.pillSize.height)
        .background {
            RoundedRectangle(cornerRadius: Metrics.pillCornerRadius)
                .fill(Color(theme.palette.surface0))
                .opacity(isHovering ? 1 : 0)
        }
        .frame(width: Metrics.hitWidth, height: PaneChrome.titleRowHeight)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
            // A pane drag owns the cursor for its whole duration
            // (`DragCoordinator`'s closed hand); the pointer leaving the grip
            // on its way to a drop must not repaint it.
            guard !dragInFlight else { return }
            (hovering ? NSCursor.openHand : NSCursor.arrow).set()
        }
        .help("Drag to move this pane")
        .accessibilityLabel("Move pane")
    }
}
