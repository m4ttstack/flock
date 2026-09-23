import FlockCore
import SwiftUI

/// The attach badge: the ram and its three-echo trail beside the word
/// "flocking", running right to left along the bottom of a pane that has not
/// painted yet, the mark bouncing along above the level caption. `PaneCellView`
/// decides whether and how long it shows (`PaneLoaderPolicy`); this view
/// draws the mark and drives its clock, and `PaneLoaderStride` owns the path.
///
/// It paints no ground of its own and covers nothing. The terminal surface is
/// held at zero opacity until the badge is gone
/// (`PaneLoaderPolicy.showsTerminalSurface`), so the pane's own `theme.pane`
/// ground is what the badge runs over.
///
/// The mark's brand colours are `HerdrRamTrail`'s, shared with the app icon
/// so this can never repaint the ram in the active theme. Only the caption's
/// text colour follows `theme`. Under reduced motion it rests, still, in the
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
    @State private var dotCount = 1
    @State private var start = Date()
    /// Seeded near the real width so the first frame, drawn before it is
    /// measured, starts close to the corner rather than at the right edge.
    @State private var badgeWidth: CGFloat = 110

    private var reduceMotion: Bool { reducedMotionOverride ?? systemReduceMotion }

    private static let dotCycleInterval = 0.3

    var body: some View {
        Group {
            if reduceMotion {
                badge(elapsed: nil)
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
        .task {
            guard !reduceMotion else { return }
            await cycleDots()
        }
        // Nothing here is aimable, and the pane underneath owns every click
        // it would otherwise swallow.
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("flocking")
    }

    /// Only `.offset` changes per frame, so a running badge never forces a
    /// layout pass. Leading-anchored, so the dots growing and shrinking move
    /// the caption's tail and never the ram.
    private func run(elapsed: Double) -> some View {
        GeometryReader { proxy in
            let inset = ChromeMetrics.Loader.badgeInset
            let x = PaneLoaderStride.leadingX(
                elapsed: elapsed, start: proxy.size.width - inset - badgeWidth,
                badgeWidth: badgeWidth, boxWidth: proxy.size.width
            )
            badge(elapsed: elapsed)
                .fixedSize()
                .onGeometryChange(for: CGFloat.self, of: \.size.width) { badgeWidth = $0 }
                .offset(x: x)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(.bottom, inset)
        }
    }

    private func badge(elapsed: Double?) -> some View {
        HStack(spacing: ChromeMetrics.Loader.spacing) {
            mark(elapsed: elapsed)
            Text(caption)
                .font(ChromeType.loaderCaption)
                .foregroundStyle(theme.textLabel)
        }
    }

    private var caption: String {
        reduceMotion || frozenElapsed != nil ? "flocking..." : "flocking" + String(repeating: ".", count: dotCount)
    }

    /// The badge's own cadence, cancelled for free when the view goes: nothing
    /// external drives this, so it has to keep its own count.
    private func cycleDots() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Self.dotCycleInterval))
            guard !Task.isCancelled else { return }
            dotCount = dotCount == 3 ? 1 : dotCount + 1
        }
    }

    private func mark(elapsed: Double?) -> some View {
        let size = ChromeMetrics.Loader.badgeMarkSize
        let lift = elapsed.map { size * PaneLoaderStride.hopHeightFraction * PaneLoaderStride.hopLift(elapsed: $0) } ?? 0
        return HerdrRamMark(size: size).offset(y: -lift)
    }
}
