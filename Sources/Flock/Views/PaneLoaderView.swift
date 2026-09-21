import FlockCore
import SwiftUI

/// The mark and "gathering the flock..." shown while a pane's herdr surface
/// attaches: the ram over its own three-echo trail, catching up to itself on
/// a loop. `PaneCellView` decides how long this stays on screen
/// (`PaneLoaderPolicy`); this view only draws the mark and drives its clock.
///
/// The echoes' rest position and the mark's own brand colours are
/// `HerdrRamTrail`'s, shared with the app icon so this can never trace a
/// different animal or repaint it in the active theme. Only the ellipsis and
/// the caption's own text colour follow `theme`; the mark does not. Only the
/// echoes move -- the leader is what they are catching up TO, so it never
/// itself moves or scales.
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

    private static let fadeInDuration = 0.25
    private static let dotCycleInterval = 0.5

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: ChromeMetrics.Loader.spacing) {
                mark(size: ChromeMetrics.Loader.markSize(paneSize: proxy.size))
                Text(caption)
                    .font(ChromeType.loaderCaption)
                    .foregroundStyle(theme.textLabel)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Opaque and covering the whole pane: this sits directly over the
        // live terminal surface (kept mounted underneath at all times, see
        // `PaneCellView`), and a transparent loader would let its output
        // show straight through.
        .background(theme.pane)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.easeOut(duration: Self.fadeInDuration)) { appeared = true }
        }
        .task {
            guard !reduceMotion else { return }
            await cycleDots()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("gathering the flock")
    }

    private var caption: String {
        reduceMotion ? "gathering the flock..." : "gathering the flock" + String(repeating: ".", count: dotCount)
    }

    /// The card's own cadence, cancelled for free when the view goes: nothing
    /// external drives this, so it has to keep its own count.
    private func cycleDots() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Self.dotCycleInterval))
            guard !Task.isCancelled else { return }
            dotCount = dotCount == 3 ? 1 : dotCount + 1
        }
    }

    @ViewBuilder
    private func mark(size: CGFloat) -> some View {
        let square = CGSize(width: size, height: size)
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
    /// `.offset` is the only thing animated per frame, so a running loader
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
