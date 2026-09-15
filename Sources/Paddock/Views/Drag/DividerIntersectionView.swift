import AppKit
import PaddockCore
import SwiftUI

/// The small square where a vertical divider's hit band crosses a
/// horizontal one's (a T or a plus). Each `DividerHandleView` only covers
/// its OWN band, so neither can resolve a press landing in a shared square
/// on its own; this view sits on top of both (added after them in
/// `PaneCanvas`'s ZStack) and forwards to whichever one
/// `DividerIntersections.resolve` names. Draws nothing itself -- each
/// divider's own line and live-ratio paint are unaffected by which one a
/// press here ends up dragging.
struct DividerIntersectionView: View {
    let intersection: DividerIntersection

    @Environment(DividerDragCoordinator.self) private var dividerDrag
    @Environment(DragCoordinator.self) private var drag
    /// Locked on the first `onChanged`, so a pointer that wanders across
    /// the diagonal mid-drag keeps dragging the divider the press started
    /// on -- matching `DividerHandleView`'s own single-divider gesture.
    @State private var lockedDivider: DividerHandle?

    var body: some View {
        Color.clear
            .frame(width: intersection.square.width, height: intersection.square.height)
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                guard !drag.isPaneDragInFlight else { return }
                switch phase {
                case .active(let location):
                    (winner(at: location).isVerticalLine ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set()
                case .ended:
                    NSCursor.arrow.set()
                }
            }
            .gesture(dragGesture)
            .accessibilityIdentifier("paddock.canvas.divider.intersection.\(intersection.id)")
    }

    private func winner(at localPoint: CGPoint) -> DividerHandle {
        let point = CGPoint(x: intersection.square.minX + localPoint.x, y: intersection.square.minY + localPoint.y)
        return DividerIntersections.resolve(intersection, at: point)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .local)
            .onChanged { value in
                let divider = lockedDivider ?? winner(at: value.startLocation)
                if lockedDivider == nil {
                    lockedDivider = divider
                    dividerDrag.began(divider)
                }
                let pointer = CGPoint(x: intersection.square.minX + value.location.x, y: intersection.square.minY + value.location.y)
                dividerDrag.moved(to: pointer, for: divider)
            }
            .onEnded { _ in
                lockedDivider = nil
                dividerDrag.ended()
            }
    }
}
