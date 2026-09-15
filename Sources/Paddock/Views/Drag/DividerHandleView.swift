import AppKit
import PaddockCore
import SwiftUI

/// One divider's hit zone and paint. Placed by the caller via `.offset` at
/// `band`'s origin, the same convention `PaneCanvas` already uses for
/// `PaneCellView` -- this view sizes itself to `band`, which is wider than
/// the gutter it paints (`DividerBand.thickness` vs. the drawn line), so the
/// hit zone reaches into both neighbors' chrome insets without ever meeting
/// their terminal surfaces. A faint separator line at rest; brightens plus a
/// pip on hover; an accent line plus the live ratio while dragging.
///
/// A divider drag is NOT routed through `DragCoordinator`/`DragController`:
/// it resolves no drop target, has no ghost, and never spring-loads, so
/// `DividerDragCoordinator` (this file's sibling) is its own small
/// controller rather than a new `DragController.Phase` case built around
/// machinery this gesture shares none of. It is read from the environment,
/// not owned here: this view is only ever the thing that STARTS a drag,
/// never the only thing that can end one -- see `DividerDragCoordinator`'s
/// own doc comment for what went wrong when a per-divider `@State` instance
/// used to own it instead.
struct DividerHandleView: View {
    let theme: Theme
    let divider: DividerHandle
    /// `divider.hitBand(thickness: DividerBand.thickness)` -- the caller's
    /// own, so its placement offset and this view's local space agree on
    /// the same rect.
    let band: CGRect

    @Environment(DividerDragCoordinator.self) private var dividerDrag
    @Environment(DragCoordinator.self) private var drag
    @State private var isHovering = false

    private var isVertical: Bool { divider.isVerticalLine }

    /// This divider's own live ratio, or `nil` when it is not the one
    /// `dividerDrag` is currently tracking -- another divider's drag (or
    /// none) must never paint THIS one's accent line.
    private var liveRatio: Double? {
        guard let live = dividerDrag.liveOverride, live.tabID == divider.tabID, live.path == divider.path else { return nil }
        return live.ratio
    }

    var body: some View {
        ZStack {
            if let liveRatio {
                liveHandle(at: liveRatio)
            } else {
                handle(color: isHovering ? theme.accent : theme.overlay0)
            }
        }
        .frame(width: band.width, height: band.height)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
            // A pane drag already owns the cursor for its whole duration
            // (`DragCoordinator`'s own push); the pointer can pass over this
            // gutter mid-drag without landing a divider drag of its own, and
            // must not repaint the closed hand away underneath it.
            guard !drag.isPaneDragInFlight else { return }
            (hovering ? (isVertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown) : NSCursor.arrow).set()
        }
        .gesture(dragGesture)
        .accessibilityIdentifier("paddock.canvas.divider.\(pathLabel)")
    }

    private var pathLabel: String {
        divider.path.isEmpty ? "root" : divider.path.map { $0 ? "1" : "0" }.joined()
    }

    /// `.local` so `value.location` is relative to this view's own bounds
    /// (sized to `band`), which `band.origin` then translates back into the
    /// shared canvas-local space every geometry input already lives in.
    /// `began()` is called on every callback while not yet dragging rather
    /// than gated on a separate flag: the machine's own latch
    /// (`DragGestureMachine`, composed inside `DividerDragMachine`) is what
    /// actually decides whether a begin takes effect, so a stray re-arm
    /// attempt during `.cancelledAwaitingRelease` is already a no-op there.
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .local)
            .onChanged { value in
                if !dividerDrag.isDragging {
                    dividerDrag.began(divider)
                }
                let pointer = CGPoint(x: band.minX + value.location.x, y: band.minY + value.location.y)
                dividerDrag.moved(to: pointer, for: divider)
            }
            .onEnded { _ in dividerDrag.ended() }
    }

    /// Always drawn, so the divider is findable without hunting for it:
    /// a capsule centered along the divider, a fifth of its length.
    private func handle(color: Color) -> some View {
        let length = DividerBand.handleLength(
            forDividerLength: isVertical ? divider.frame.height : divider.frame.width
        )
        return Capsule()
            .fill(color)
            .frame(
                width: isVertical ? DividerBand.handleThickness : length,
                height: isVertical ? length : DividerBand.handleThickness
            )
    }

    /// The same handle, moved to the boundary the drag is previewing.
    private func liveHandle(at ratio: Double) -> some View {
        let boundary = DividerDragMath.boundary(forRatio: ratio, divider: divider)
        let localOffset = isVertical ? boundary - divider.frame.midX : boundary - divider.frame.midY

        let handleLength = DividerBand.handleLength(
            forDividerLength: isVertical ? divider.frame.height : divider.frame.width
        )
        return ZStack {
            handle(color: theme.accent)
            // Clear of the handle so the percentage never covers what the
            // pointer is holding.
            ratioLabel(ratio)
                .offset(y: isVertical ? -(handleLength / 2 + 14) : -16)
        }
        .offset(x: isVertical ? localOffset : 0, y: isVertical ? 0 : localOffset)
    }

    private func ratioLabel(_ ratio: Double) -> some View {
        Text("\(Int((ratio * 100).rounded()))%")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(theme.chromeTextStrong)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(theme.panelBg))
            .fixedSize()
    }
}
