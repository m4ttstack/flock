import FlockCore
import SwiftUI

/// The attach badge: the ram and its three-echo trail ambling right to left
/// along the bottom of a pane that has not painted yet, bouncing along a
/// gently winding path and dropping dots off its back, a goat trail that
/// fades behind it.
/// `PaneCellView` decides whether and how long it shows (`PaneLoaderPolicy`);
/// this view draws it and drives its clock, and `PaneLoaderStride` owns the
/// path.
///
/// It paints no ground of its own and covers nothing. The terminal surface is
/// held at zero opacity until the badge is gone
/// (`PaneLoaderPolicy.showsTerminalSurface`), so the pane's own `theme.pane`
/// ground is what the badge runs over.
///
/// The mark's brand colours are `HerdrRamTrail`'s, shared with the app icon
/// so this can never repaint the ram in the active theme; the trail's dots
/// follow `theme`. Under reduced motion the mark rests, still, in the
/// bottom-right corner the run starts from.
struct PaneLoaderView: View {
    let theme: Theme
    /// Lets a render test force the static path deterministically. Always
    /// `nil` in the app, where the real environment value decides.
    var reducedMotionOverride: Bool?
    /// Lets a render test freeze the run at one instant. Always `nil` in the
    /// app, where the clock runs from the badge's appearance.
    var frozenElapsed: Double?

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var appeared = false
    @State private var start = Date()

    private var reduceMotion: Bool { reducedMotionOverride ?? systemReduceMotion }

    private static let markSize = ChromeMetrics.Loader.badgeMarkSize
    private static let dotSize: CGFloat = 3
    /// Under the leader's body rather than the whole mark's middle: the
    /// echoes stretch the mark's box up and to the right of the ram itself.
    /// The ram's ground follows the path at this point.
    private static let footFraction: CGFloat = 0.35
    /// Just past the farthest echo, so the trail comes off the back of the
    /// flock rather than out from under it.
    private static let tailGap: CGFloat = 2
    /// The ram's hooves sit this far above the bottom of the mark's box, which
    /// carries a margin; the trail lies on that line, not the box's edge.
    private static let hoofLine: CGFloat = 2

    var body: some View {
        Group {
            if reduceMotion {
                HerdrRamMark(size: Self.markSize)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(ChromeMetrics.Loader.badgeInset)
            } else if let frozenElapsed {
                run(elapsed: frozenElapsed)
            } else {
                TimelineView(.animation) { context in
                    run(elapsed: context.date.timeIntervalSince(start))
                }
            }
        }
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.easeOut(duration: PaneLoaderPolicy.dismissCrossFade)) { appeared = true }
        }
        // Nothing here is aimable, and the pane underneath owns every click
        // it would otherwise swallow.
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("flocking")
    }

    /// Only offsets and opacities change per frame, so a running badge never
    /// forces a layout pass.
    private func run(elapsed: Double) -> some View {
        GeometryReader { proxy in
            let inset = ChromeMetrics.Loader.badgeInset
            let width = proxy.size.width
            let start = width - inset - Self.markSize
            let x = PaneLoaderStride.leadingX(elapsed: elapsed, start: start, badgeWidth: Self.markSize, boxWidth: width)
            let ground = PaneLoaderStride.winding(atX: x + Self.markSize * Self.footFraction)
            let hop = Self.markSize * PaneLoaderStride.hopHeightFraction * PaneLoaderStride.hopLift(elapsed: elapsed)
            ZStack(alignment: .bottomLeading) {
                ForEach(
                    PaneLoaderStride.trail(
                        elapsed: elapsed, start: start, badgeWidth: Self.markSize, boxWidth: width,
                        tailOffset: Self.markSize + Self.tailGap
                    ),
                    id: \.x
                ) { dot in
                    Circle()
                        .fill(theme.textLabel)
                        .frame(width: Self.dotSize, height: Self.dotSize)
                        .opacity(dot.opacity)
                        .offset(x: dot.x - Self.dotSize / 2, y: -(dot.lift + Self.hoofLine))
                }
                HerdrRamMark(size: Self.markSize)
                    .offset(x: x, y: -(ground + hop))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(.bottom, inset)
        }
    }
}
