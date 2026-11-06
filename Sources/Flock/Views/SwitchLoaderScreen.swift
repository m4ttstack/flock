import FlockCore
import SwiftUI

/// Covers the window while a profile switch or a machine connection has no
/// panes to show. Drawn from `SwitchLoaderRun` and the clock alone, so the
/// rebuild a switch makes draws the same frame it would have.
struct SwitchLoaderScreen: View {
    let theme: Theme
    let run: SwitchLoaderRun
    var isSettled = false
    /// Kept where the rail draws it, so switching away needs no menu.
    let profilePicker: ProfilePickerContext
    var profileDot: ProfileConnectionDot?
    var onSwitchToDefault: () -> Void = {}
    /// Renders this run time and nothing else, for stills.
    var stillAt: Double?
    var reduceMotionOverride: Bool?

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(RailWidthStore.self) private var railWidth: RailWidthStore?

    private var reduceMotion: Bool { reduceMotionOverride ?? systemReduceMotion }

    var body: some View {
        Group {
            if let stillAt {
                frameView(run.frame(at: stillAt))
            } else {
                TimelineView(.animation(minimumInterval: nil, paused: isSettled)) { context in
                    frameView(run.frame(at: context.date.timeIntervalSinceReferenceDate - run.startedAt))
                }
            }
        }
        .allowsHitTesting(!run.isFinishing)
        // Must match `MainWindow`'s own floor, which this screen hands over to.
        .frame(minWidth: 900, minHeight: 560)
        .ignoresSafeArea(edges: .top)
        .background(TitlebarConfigurator(windowBg: theme.chrome))
        .accessibilityIdentifier("flock.switchLoader.screen")
    }

    private func frameView(_ frame: SwitchLoaderFrame) -> some View {
        SwitchLoaderFrameView(frame: frame, theme: theme, reduceMotion: reduceMotion, onSwitchToDefault: onSwitchToDefault)
            .overlay(alignment: .topLeading) {
                ProfilePicker(theme: theme, context: profilePicker, currentDot: profileDot)
                    .padding(.top, ChromeMetrics.TitleBar.height + ChromeMetrics.Rail.verticalPadding)
                    .padding(.horizontal, ChromeMetrics.Rail.horizontalPadding)
                    .frame(width: railWidth?.width ?? RailWidth.default)
                    .opacity(frame.screenOpacity)
            }
    }
}

/// One frame of the loader. Every slot has its size from the first frame,
/// so no change of copy moves anything.
struct SwitchLoaderFrameView: View {
    let frame: SwitchLoaderFrame
    let theme: Theme
    var reduceMotion = false
    var onSwitchToDefault: () -> Void = {}

    private typealias Timing = SwitchLoaderRun.Timing

    private enum Metrics {
        static let markSize: CGFloat = 72
        static let glowDiameter: CGFloat = 280
        static let slotWidth: CGFloat = 460
        static let titleHeight: CGFloat = 24
        /// Two lines: a failure's reason and hint.
        static let statusHeight: CGFloat = 36
        static let slide: CGFloat = 4
        static let trackWidth: CGFloat = 140
        static let trackHeight: CGFloat = 3
        static let shimmerWidth: CGFloat = 56
        /// The leader's own centre against the mark's box, which centres the
        /// spread composition; the glow follows the mass as the echoes merge.
        static let leaderOffset = CGSize(width: -11, height: 5)
        static let exitShrink: CGFloat = 0.02
    }

    private static let lavender = Color(HerdrRamTrail.Colors.leader)

    private var isLight: Bool {
        let bg = theme.palette.panelBg
        return 0.2126 * Double(bg.red) + 0.7152 * Double(bg.green) + 0.0722 * Double(bg.blue) > 128
    }

    /// The theme's attention colour. A light theme's yellow is often darkened
    /// to brown for contrast, so there the more saturated of its yellow and
    /// orange wins.
    private var amber: Color {
        let yellow = theme.palette.yellow, orange = theme.palette.peach
        guard isLight else { return theme.yellow }
        func saturation(_ c: RGB) -> Double {
            let high = max(c.red, c.green, c.blue), low = min(c.red, c.green, c.blue)
            return high == 0 ? 0 : Double(high - low) / Double(high)
        }
        return Color(saturation(orange) > saturation(yellow) ? orange : yellow)
    }

    var body: some View {
        VStack(spacing: 0) {
            mark
            crossfadeSlot(frame.title, height: Metrics.titleHeight, lines: 1) {
                Text($0)
                    .font(ChromeType.inter(17, .semibold))
                    .tracking(-0.2)
                    .foregroundStyle(theme.textStrong)
            }
            .padding(.top, 30)
            crossfadeSlot(frame.status, height: Metrics.statusHeight, lines: 2) {
                Text($0)
                    .font(ChromeType.inter(13))
                    .foregroundStyle(theme.textDim)
            }
            .padding(.top, 4)
            track
                .padding(.top, 8)
            switchButton
                .padding(.top, 26)
        }
        .scaleEffect(1 - Metrics.exitShrink * frame.exit)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.chrome)
        .opacity(frame.screenOpacity)
    }

    // MARK: mark

    private var reducedPulse: Double {
        0.5 + 0.5 * cos(2 * .pi * frame.runTime / Timing.reducedPulsePeriod)
    }

    private var mark: some View {
        let snapshot = frame
        return Group {
            if reduceMotion {
                HerdrRamMark(size: Metrics.markSize)
                    .opacity(frame.isFailed ? 1 : 0.72 + 0.28 * reducedPulse)
            } else {
                HerdrRamMark(size: Metrics.markSize, progress: { snapshot.merge(delay: $0) })
            }
        }
        .frame(width: Metrics.markSize, height: Metrics.markSize)
        .background { glow(merge: reduceMotion ? 0.3 * reducedPulse : frame.meanMerge) }
    }

    private func glow(merge: Double) -> some View {
        let peak = (isLight ? 0.11 : 0.13) + (isLight ? 0.07 : 0.12) * merge
        let alpha = peak * frame.glow
        return RadialGradient(
            stops: [
                .init(color: Self.lavender.opacity(alpha), location: 0),
                .init(color: Self.lavender.opacity(alpha * 0.45), location: 0.32),
                .init(color: Self.lavender.opacity(alpha * 0.12), location: 0.62),
                .init(color: Self.lavender.opacity(0), location: 1),
            ],
            center: .center, startRadius: 0, endRadius: Metrics.glowDiameter / 2
        )
        .frame(width: Metrics.glowDiameter, height: Metrics.glowDiameter)
        .scaleEffect(0.92 + 0.08 * merge)
        .offset(
            x: reduceMotion ? 0 : Metrics.leaderOffset.width * merge,
            y: reduceMotion ? 0 : Metrics.leaderOffset.height * merge
        )
        .allowsHitTesting(false)
    }

    // MARK: copy

    /// The outgoing line is mostly gone before the incoming one shows, so
    /// the two never read as one smudged line. Text sits at the top of its
    /// slot, so a second line grows downward into space already reserved.
    private func crossfadeSlot(
        _ line: SwitchLoaderFrame.Crossfade, height: CGFloat, lines: Int, @ViewBuilder text: @escaping (String) -> some View
    ) -> some View {
        ZStack(alignment: .top) {
            if let previous = line.previous, line.mix < 1 {
                text(previous)
                    .lineLimit(lines)
                    .multilineTextAlignment(.center)
                    .opacity(1 - SwitchLoaderEasing.clamp(line.mix / 0.6))
                    .offset(y: -Metrics.slide * line.mix)
            }
            text(line.current)
                .lineLimit(lines)
                .multilineTextAlignment(.center)
                .opacity(SwitchLoaderEasing.clamp((line.mix - 0.4) / 0.6))
                .offset(y: Metrics.slide * (1 - line.mix))
        }
        .frame(width: Metrics.slotWidth, height: height, alignment: .top)
    }

    // MARK: progress

    /// Under reduced motion the shimmer's sweep becomes a slow brightening
    /// of the whole track.
    private var trackPulse: Double {
        guard reduceMotion, !frame.isFailed else { return 1 }
        return 1 + 0.6 * reducedPulse
    }

    private var shimmerColor: Color {
        isLight ? Color.white.opacity(0.95) : theme.textStrong.opacity(0.62)
    }

    private var track: some View {
        let travel = Metrics.trackWidth + Metrics.shimmerWidth
        return ZStack(alignment: .leading) {
            Capsule().fill(theme.textLabel.opacity((isLight ? 0.34 : 0.2) * trackPulse))
            LinearGradient(
                colors: [shimmerColor.opacity(0), shimmerColor, shimmerColor.opacity(0)],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(width: Metrics.shimmerWidth)
            .offset(x: -Metrics.shimmerWidth + travel * frame.shimmerPosition)
            .opacity(reduceMotion ? 0 : frame.shimmerOpacity)
            Capsule().fill(amber).opacity(frame.warn * 0.85)
        }
        .frame(width: Metrics.trackWidth, height: Metrics.trackHeight)
        .clipShape(Capsule())
    }

    // MARK: failure

    private var switchButton: some View {
        Button("Switch to Default", action: onSwitchToDefault)
            .buttonStyle(NoHerdrPrimaryActionStyle(theme: theme))
            .opacity(frame.failReveal)
            .offset(y: Metrics.slide * (1 - frame.failReveal))
            .allowsHitTesting(frame.failReveal > 0.5)
            .accessibilityHidden(frame.failReveal == 0)
            .accessibilityIdentifier("flock.switchLoader.switchToDefault")
    }
}
