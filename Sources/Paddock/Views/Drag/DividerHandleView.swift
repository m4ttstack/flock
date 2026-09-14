import AppKit
import PaddockCore
import SwiftUI

/// One divider's hit zone and paint. Placed by the caller via `.frame` and
/// `.offset` at `divider.frame`, the same convention `PaneCanvas` already
/// uses for `PaneCellView` -- this view only fills whatever box it is given.
/// Invisible at rest; a pip on hover; an accent line plus the live ratio
/// while dragging.
///
/// A divider drag is NOT routed through `DragCoordinator`/`DragController`:
/// it resolves no drop target, has no ghost, and never spring-loads, so
/// `DividerDragCoordinator` (this file's sibling) is its own small
/// controller rather than a new `DragController.Phase` case built around
/// machinery this gesture shares none of.
struct DividerHandleView: View {
    let theme: Theme
    let divider: DividerHandle
    /// Every divider in this tab, canvas-local -- `DividerDragMath` walks
    /// this to recover a nested split's own along-axis extent.
    let siblingDividers: [DividerHandle]
    /// The canvas's own bounds, same space as `divider.frame` and
    /// `siblingDividers`.
    let canvasFrame: CGRect

    @State private var coordinator: DividerDragCoordinator
    @State private var isHovering = false

    init(
        theme: Theme, divider: DividerHandle, siblingDividers: [DividerHandle], canvasFrame: CGRect,
        commit: @escaping (TabID, [Bool], Double) async -> Void
    ) {
        self.theme = theme
        self.divider = divider
        self.siblingDividers = siblingDividers
        self.canvasFrame = canvasFrame
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
        .accessibilityIdentifier("paddock.canvas.divider.\(pathLabel)")
    }

    private var pathLabel: String {
        divider.path.isEmpty ? "root" : divider.path.map { $0 ? "1" : "0" }.joined()
    }

    /// `.local` so `value.location` is relative to this view's own bounds
    /// (sized to `divider.frame`), which `divider.frame.origin` then
    /// translates back into the shared canvas-local space every geometry
    /// input already lives in.
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .local)
            .onChanged { value in
                let pointer = CGPoint(x: divider.frame.minX + value.location.x, y: divider.frame.minY + value.location.y)
                if !coordinator.isDragging {
                    coordinator.began(divider, at: pointer, dividers: siblingDividers, canvas: canvasFrame)
                }
                coordinator.moved(to: pointer, dividers: siblingDividers, canvas: canvasFrame)
            }
            .onEnded { _ in coordinator.ended() }
    }

    private var pip: some View {
        Capsule()
            .fill(theme.overlay1)
            .frame(width: isVertical ? 3 : 16, height: isVertical ? 16 : 3)
    }

    private func liveLine(at ratio: Double) -> some View {
        let boundary = DividerDragMath.boundary(forRatio: ratio, divider: divider, dividers: siblingDividers, canvas: canvasFrame)
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
