import PaddockCore
import SwiftUI

/// A thin bar at a pane box's right edge mirroring herdr's own scroll state
/// for the pane (`PaneRecord.scroll`, fed by the per-pane `pane.scroll_changed`
/// feed): visible only while the shared viewport sits above its tail, thumb
/// length the viewport's share of the scrollback, position how far up it is.
/// Display only, never hit-testable: the wheel still moves herdr's viewport
/// through the control FIFO, and this just reflects where it landed.
struct PaneScrollIndicator: View {
    static let width: CGFloat = 4
    let theme: Theme
    let scroll: ScrollInfo?

    var body: some View {
        GeometryReader { proxy in
            if let scroll, let thumb = ScrollIndicatorGeometry.thumb(for: scroll, trackLength: proxy.size.height) {
                ZStack(alignment: .top) {
                    Capsule().fill(theme.textLabel.opacity(0.18))
                    Capsule()
                        .fill(theme.textLabel)
                        .frame(height: thumb.length)
                        .offset(y: thumb.offset)
                }
                .frame(width: Self.width, height: proxy.size.height)
                .transition(.opacity)
            }
        }
        .frame(width: Self.width)
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.15), value: scroll)
    }
}
