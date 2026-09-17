import FlockCore
import SwiftUI

/// The reorder marker: a thin accent line in the gap a drop would insert
/// into, capped by a dot on its leading end. Both rects come from
/// `InsertionBarGeometry`; this only paints them, in the drag space.
struct InsertionBar: View {
    let theme: Theme
    let mark: DragCoordinator.InsertionMark

    var body: some View {
        ZStack(alignment: .topLeading) {
            Capsule()
                .fill(theme.accent)
                .frame(width: mark.bar.width, height: mark.bar.height)
                .offset(x: mark.bar.minX, y: mark.bar.minY)
            Circle()
                .fill(theme.accent)
                .frame(width: mark.dot.width, height: mark.dot.height)
                .offset(x: mark.dot.minX, y: mark.dot.minY)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
