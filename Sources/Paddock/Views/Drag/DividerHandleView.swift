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
/// machinery this gesture shares none of.
///
/// `onLiveRatioChange` reports this divider's own live ratio (`nil` when not
/// dragging) up to `PaneCanvas`, which folds it into `CanvasGeometry` as a
/// live override so the panes on both sides actually follow the drag rather
/// than only the accent line moving.
struct DividerHandleView: View {
    let theme: Theme
    let divider: DividerHandle
    let commit: (TabID, [Bool], Double) async -> Void
    let onLiveRatioChange: (Double?) -> Void

    @State private var coordinator: DividerDragCoordinator
    @State private var isHovering = false

    init(theme: Theme, divider: DividerHandle, commit: @escaping (TabID, [Bool], Double) async -> Void, onLiveRatioChange: @escaping (Double?) -> Void) {
        self.theme = theme
        self.divider = divider
        self.commit = commit
        self.onLiveRatioChange = onLiveRatioChange
        _coordinator = State(initialValue: DividerDragCoordinator(commit: commit))
    }

    private var isVertical: Bool { divider.direction == .right }

    var body: some View {
        ZStack {
            if let liveRatio = coordinator.liveRatio {
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
        .onChange(of: coordinator.liveRatio) { _, new in onLiveRatioChange(new) }
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
                if !coordinator.isDragging {
                    coordinator.began(divider)
                }
                let pointer = CGPoint(x: divider.frame.minX + value.location.x, y: divider.frame.minY + value.location.y)
                coordinator.moved(to: pointer)
            }
            .onEnded { _ in coordinator.ended() }
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
