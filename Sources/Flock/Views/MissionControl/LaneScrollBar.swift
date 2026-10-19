import FlockCore
import SwiftUI

/// An Overview lane's scroll bar, drawn here because AppKit's scroller takes
/// neither a width nor a colour: faint and thin at rest, up while the pointer
/// is over the lane, and draggable. It runs in the lane's trailing padding,
/// which the scroll view reaches into.
struct LaneScrollBar: ViewModifier {
    let theme: Theme
    @Binding var position: ScrollPosition

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var extent = Extent()
    @State private var isHovering = false
    /// The thumb's offset when the drag began; nil while nothing drags it.
    @State private var dragOrigin: CGFloat?

    private typealias M = ChromeMetrics.MissionControl

    struct Extent: Equatable {
        var offset: CGFloat = 0
        var content: CGFloat = 0
        var visible: CGFloat = 0
    }

    func body(content: Content) -> some View {
        content
            .scrollIndicators(.never)
            .onScrollGeometryChange(for: Extent.self) {
                Extent(offset: $0.visibleRect.minY, content: $0.contentSize.height, visible: $0.visibleRect.height)
            } action: { _, new in
                extent = new
            }
            .overlay(alignment: .topTrailing) { bar }
            .onHover { isHovering = $0 }
            .padding(.trailing, -M.laneScrollerGutter)
    }

    private var bar: some View {
        GeometryReader { proxy in
            let track = proxy.size.height
            if let thumb = ScrollIndicatorGeometry.thumb(
                offset: extent.offset, content: extent.content, visible: extent.visible, trackLength: track,
                minimumLength: M.laneScrollBarMinLength
            ) {
                let raised = isHovering || dragOrigin != nil
                Capsule()
                    .fill(theme.textLabel.opacity(raised ? M.laneScrollBarRaisedOpacity : M.laneScrollBarRestOpacity))
                    .frame(width: raised ? M.laneScrollBarRaisedWidth : M.laneScrollBarRestWidth, height: thumb.length)
                    .padding(.trailing, M.laneScrollBarEdgeInset)
                    .frame(width: M.laneScrollerGutter, alignment: .trailing)
                    .contentShape(Rectangle())
                    .offset(y: thumb.offset)
                    .gesture(drag(thumb, track: track))
                    .animation(reduceMotion ? nil : .easeOut(duration: M.laneScrollBarFade), value: raised)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private func drag(_ thumb: ScrollIndicatorGeometry.Thumb, track: CGFloat) -> some Gesture {
        // In the window's space: the thumb moves under the pointer, and a
        // translation in its own space would chase it.
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                let origin = dragOrigin ?? thumb.offset
                dragOrigin = origin
                position.scrollTo(y: ScrollIndicatorGeometry.contentOffset(
                    forThumbAt: origin + value.translation.height, thumb: thumb,
                    content: extent.content, visible: extent.visible, trackLength: track
                ))
            }
            .onEnded { _ in dragOrigin = nil }
    }
}
