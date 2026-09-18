import AppKit
import FlockCore
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
    /// Which divider the pointer would grab at its current spot, so the
    /// resize cursor matches the drag a press there would start.
    @State private var hoverResolvesVertical = true

    var body: some View {
        Color.clear
            .frame(width: intersection.square.width, height: intersection.square.height)
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                if case .active(let location) = phase {
                    hoverResolvesVertical = winner(atLocal: location).isVerticalLine
                }
            }
            .pointerStyle(drag.isPaneDragInFlight ? nil : (hoverResolvesVertical ? .columnResize : .rowResize))
            .gesture(dragGesture)
            .accessibilityIdentifier("flock.canvas.divider.intersection.\(intersection.id)")
    }

    /// `localPoint` is in this square's own space, which only the hover
    /// callback works in; the gesture already reads canvas points.
    private func winner(atLocal localPoint: CGPoint) -> DividerHandle {
        DividerIntersections.resolve(
            intersection,
            at: CGPoint(x: intersection.square.minX + localPoint.x, y: intersection.square.minY + localPoint.y)
        )
    }

    /// Measured in the canvas's own named space, like `DividerHandleView`'s:
    /// `intersection.square` is derived from the two bands this gesture
    /// moves, so reconstructing a canvas point from it would read the
    /// pointer against a rect the drag itself displaces.
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(DragSpace.canvasContent))
            .onChanged { value in
                let divider = lockedDivider ?? DividerIntersections.resolve(intersection, at: value.startLocation)
                if lockedDivider == nil {
                    lockedDivider = divider
                    dividerDrag.began(divider)
                }
                dividerDrag.moved(to: value.location, for: divider)
            }
            .onEnded { value in
                let divider = lockedDivider ?? DividerIntersections.resolve(intersection, at: value.startLocation)
                lockedDivider = nil
                dividerDrag.ended(at: value.location, for: divider)
            }
    }
}
