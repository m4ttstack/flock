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

    @ViewBuilder
    private var mark: some View {
        let square = CGSize(
            width: ChromeMetrics.Loader.badgeMarkSize, height: ChromeMetrics.Loader.badgeMarkSize
        )
        if reduceMotion {
            trail(in: square) { _ in 0 }
        } else {
            TimelineView(.animation) { context in
                let elapsed = context.date.timeIntervalSince(start)
                trail(in: square) { delay in PaneLoaderChoreography.mergeProgress(elapsed: elapsed, startDelay: delay) }
            }
        }
    }

    /// `progress` maps an echo's own start delay to how merged it is right
    /// now (0 rest, 1 merged with the leader). The rest path never moves;
    /// `.offset` is the only thing animated per frame, so a running badge
    /// never forces a layout pass.
    private func trail(in square: CGSize, progress: @escaping (Double) -> Double) -> some View {
        ZStack {
            ForEach(Array(HerdrRamTrail.echoes.enumerated()), id: \.offset) { index, echo in
                let merge = progress(echo.startDelay)
                let offset = HerdrRamTrail.offset(restBackSteps: echo.restBackSteps, in: square, progress: merge)
                Path(HerdrRamTrail.path(in: square))
                    .fill(echoColor(index))
                    .opacity(echo.restOpacity - PaneLoaderChoreography.mergeOpacityDrop * merge)
                    .offset(x: offset.width, y: offset.height)
            }
            Path(HerdrRamTrail.path(in: square))
                .fill(Color(HerdrRamTrail.Colors.leader))
        }
        .frame(width: square.width, height: square.height)
        // `HerdrRamTrail.path` is fit the way `make-icon.swift` fits it into
        // a bottom-left-origin, y-up `CGContext`; SwiftUI's own `Path` space
        // is top-left-origin, y-down, so this is the one place that
        // reconciles the two rather than the shared geometry carrying a
        // SwiftUI-specific flip.
        .scaleEffect(x: 1, y: -1)
    }

    private func echoColor(_ index: Int) -> Color {
        Color(HerdrRamTrail.Colors.echoes[index])
    }
}
