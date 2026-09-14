import AppKit
import PaddockCore
import SwiftUI

/// One divider's hit zone and paint. Placed by the caller via `.offset` at
/// `divider.frame`'s origin, the same convention `PaneCanvas` already uses
/// for `PaneCellView` -- this view sizes itself to `divider.frame`. Invisible
/// at rest; a pip on hover; an accent line plus the live ratio while
/// dragging.
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

    @Environment(DividerDragCoordinator.self) private var dividerDrag
    @State private var isHovering = false

    private var isVertical: Bool { divider.direction == .right }

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
                liveLine(at: liveRatio)
            } else if isHovering {
                pip
            }
        }
        .frame(width: divider.frame.width, height: divider.frame.height)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
            (hovering ? (isVertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown) : NSCursor.arrow).set()
        }
        .gesture(dragGesture)
        .accessibilityIdentifier("paddock.canvas.divider.\(pathLabel)")
    }

    private var pathLabel: String {
        divider.path.isEmpty ? "root" : divider.path.map { $0 ? "1" : "0" }.joined()
    }

    /// `.local` so `value.location` is relative to this view's own bounds
    /// (sized to `divider.frame`), which `divider.frame.origin` then
    /// translates back into the shared canvas-local space every geometry
    /// input already lives in. `began()` is called on every callback while
    /// not yet dragging rather than gated on a separate flag: the machine's
    /// own latch (`DragGestureMachine`, composed inside `DividerDragMachine`)
    /// is what actually decides whether a begin takes effect, so a stray
    /// re-arm attempt during `.cancelledAwaitingRelease` is already a no-op
    /// there.
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .local)
            .onChanged { value in
                if !dividerDrag.isDragging {
                    dividerDrag.began(divider)
                }
                let pointer = CGPoint(x: divider.frame.minX + value.location.x, y: divider.frame.minY + value.location.y)
                dividerDrag.moved(to: pointer)
            }
            .onEnded { _ in dividerDrag.ended() }
    }

    private var pip: some View {
        Capsule()
            .fill(theme.overlay1)
            .frame(width: isVertical ? 3 : 16, height: isVertical ? 16 : 3)
    }

    private func liveLine(at ratio: Double) -> some View {
        let boundary = DividerDragMath.boundary(forRatio: ratio, divider: divider)
        let localOffset = isVertical ? boundary - divider.frame.midX : boundary - divider.frame.midY

        return ZStack {
            Rectangle()
                .fill(theme.accent)
                .frame(width: isVertical ? 2 : divider.frame.width, height: isVertical ? divider.frame.height : 2)
            ratioLabel(ratio)
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
