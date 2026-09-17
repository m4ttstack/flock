import AppKit
import PaddockCore
import SwiftUI

/// One divider's hit zone and paint. Placed by the caller via `.offset` at
/// `band`'s origin, the same convention `PaneCanvas` already uses for
/// `PaneCellView` -- this view sizes itself to `band`, which is wider than
/// the gutter (`DividerBand.thickness` vs. `DividerBand.gutter`), so the hit
/// zone reaches into both neighbors' chrome insets without ever meeting
/// their terminal surfaces. The visible part is only the centered handle.
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
    /// none) must never paint THIS one as live.
    private var liveRatio: Double? {
        guard let live = dividerDrag.liveOverride, live.tabID == divider.tabID, live.path == divider.path else { return nil }
        return live.ratio
    }

    var body: some View {
        ZStack {
            if let liveRatio {
                liveHandle(at: liveRatio)
            } else {
                // Hover and a live drag take a hue no pane border ever uses,
                // so an active handle never reads as the focused border beside
                // it.
                handle(color: isHovering ? theme.mauve : theme.textLabel)
            }
        }
        .frame(width: band.width, height: band.height)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        // Declarative rather than `NSCursor.set()` from a hover callback: a
        // set cursor is overwritten by the next cursor-rect or tracking-area
        // update from the panes beside the band. Withheld during a pane drag,
        // which owns the closed hand for its whole duration.
        .pointerStyle(drag.isPaneDragInFlight ? nil : (isVertical ? .columnResize : .rowResize))
        .gesture(dragGesture)
        // The handle draws as a shape and carries no text, and an element
        // with nothing to read is one SwiftUI may expose to nobody: the
        // label is what makes the divider reachable, by an assistive client
        // as much as by the identifier below.
        .accessibilityLabel("Split divider")
        .accessibilityIdentifier("paddock.canvas.divider.\(pathLabel)")
    }

    private var pathLabel: String {
        divider.path.isEmpty ? "root" : divider.path.map { $0 ? "1" : "0" }.joined()
    }

    /// Measured in the canvas's own named space, which is the space
    /// `divider.regionFrame` is already stated in, so the pointer never has
    /// to be reconstructed from `band` -- a rect this very gesture moves
    /// every frame. `began()` is called on every callback while not yet
    /// dragging rather than gated on a separate flag: the machine's own latch
    /// (`DragGestureMachine`, composed inside `DividerDragMachine`) is what
    /// actually decides whether a begin takes effect, so a stray re-arm
    /// attempt during `.cancelledAwaitingRelease` is already a no-op there.
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(DragSpace.canvasContent))
            .onChanged { value in
                if !dividerDrag.isDragging {
                    dividerDrag.began(divider)
                }
                dividerDrag.moved(to: value.location, for: divider)
            }
            .onEnded { _ in dividerDrag.ended() }
    }

    /// Always drawn, so the divider is findable without hunting for it:
    /// a thin bar with fully rounded ends, centered in the gutter.
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

    /// The geometry already rebuilt this divider's frame for the previewed
    /// ratio, so the handle stays centered in its own frame rather than being
    /// offset to a raw-ratio position the whole-cell panes never reach.
    private func liveHandle(at ratio: Double) -> some View {
        let handleLength = DividerBand.handleLength(
            forDividerLength: isVertical ? divider.frame.height : divider.frame.width
        )
        return ZStack {
            handle(color: theme.mauve)
            // Clear of the handle so the percentage never covers what the
            // pointer is holding.
            ratioLabel(ratio)
                .offset(y: isVertical ? -(handleLength / 2 + ChromeMetrics.RatioLabel.clearanceAlongHandle) : -ChromeMetrics.RatioLabel.clearanceAboveHandle)
        }
    }

    private func ratioLabel(_ ratio: Double) -> some View {
        Text("\(Int((ratio * 100).rounded()))%")
            .font(ChromeType.ratioLabel)
            .foregroundStyle(theme.textStrong)
            .padding(.horizontal, ChromeMetrics.RatioLabel.horizontalPadding)
            .padding(.vertical, ChromeMetrics.RatioLabel.verticalPadding)
            .background(RoundedRectangle(cornerRadius: PaneChrome.cornerRadius).fill(theme.chrome))
            .fixedSize()
    }
}
