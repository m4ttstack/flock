import FlockCore
import SwiftUI

/// The attach badge: the ram and its three-echo trail, catching up to itself
/// on a loop, beside the word "flocking", in the corner of a pane that has
/// not painted yet. `PaneCellView` decides whether and how long it shows
/// (`PaneLoaderPolicy`); this view draws the mark and drives its clock.
///
/// It paints no ground of its own and covers nothing. The full-pane opaque
/// version it replaces had to, because the terminal surface stayed visible
/// underneath it; the surface is now held at zero opacity until the badge is
/// gone (`PaneLoaderPolicy.showsTerminalSurface`), so the pane's own
/// `theme.pane` ground is what the badge sits on, and it can be small.
///
/// The echoes' rest position and the mark's own brand colours are
/// `HerdrRamTrail`'s, shared with the app icon so this can never trace a
/// different animal or repaint it in the active theme. Only the caption's
/// text colour follows `theme`; the mark does not. Only the echoes move --
/// the leader is what they are catching up TO, so it never itself moves.
struct PaneLoaderView: View {
    let theme: Theme
    /// Lets a render test force the static path deterministically. Always
    /// `nil` in the app, where the real environment value decides.
    var reducedMotionOverride: Bool?

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var appeared = false
    @State private var dotCount = 1
    @State private var start = Date()

    private var reduceMotion: Bool { reducedMotionOverride ?? systemReduceMotion }

    private static let dotCycleInterval = 0.3

    var body: some View {
        HStack(spacing: ChromeMetrics.Loader.spacing) {
            mark
            Text(caption)
                .font(ChromeType.loaderCaption)
                .foregroundStyle(theme.textLabel)
        }
        // Pinned to one corner rather than centred: a pane that is still
        // attaching is about to be read from the top left, and this is the
        // one place nothing is about to appear.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(ChromeMetrics.Loader.badgeInset)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.easeOut(duration: PaneLoaderPolicy.dismissCrossFade)) { appeared = true }
        }
        .task {
            guard !reduceMotion else { return }
            await cycleDots()
        }
        // Nothing here is aimable, and the pane underneath owns every click
        // it would otherwise swallow in that corner.
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("flocking")
    }

    private var caption: String {
        reduceMotion ? "flocking..." : "flocking" + String(repeating: ".", count: dotCount)
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

    /// The drawing is `HerdrRamMark`'s, shared with every other surface that
    /// shows the mark. Only the clock is this view's: the rest path never
    /// moves and `.offset` is the only thing animated per frame, so a running
    /// badge never forces a layout pass.
    @ViewBuilder
    private var mark: some View {
        if reduceMotion {
            HerdrRamMark(size: ChromeMetrics.Loader.badgeMarkSize)
        } else {
            TimelineView(.animation) { context in
                let elapsed = context.date.timeIntervalSince(start)
                HerdrRamMark(size: ChromeMetrics.Loader.badgeMarkSize) { delay in
                    PaneLoaderChoreography.mergeProgress(elapsed: elapsed, startDelay: delay)
                }
            }
        }
    }
}
