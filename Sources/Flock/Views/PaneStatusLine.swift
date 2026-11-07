import FlockCore
import SwiftUI

/// The line under a pane's header that carries its agent's status
/// (`PaneStatusLineStyle`), with a wash of the same paint rising from it into
/// the header. Only a working or blocked pane animates, and only while it is
/// in that state, so a canvas of idle shells costs nothing.
///
/// Every paint varies across the width only, so one paint serves both the
/// line and the wash: the wash is that paint stretched up the header and
/// faded toward the top.
struct PaneStatusLine: View {
    let theme: Theme
    let status: AgentStatus
    let style: PaneStatusLineStyle
    /// What a pane whose agent rests is still running (a shell job, say),
    /// which outranks the resting line as the header dot it replaces did.
    var backgroundWork: String? = nil

    private typealias M = ChromeMetrics.Pane.StatusLine

    /// Working's motion in its own colours, or background work's: the same
    /// motion in mauve, weaker and slower, so it reads as alive but secondary.
    private struct Motion {
        let color: RGB
        let partner: RGB
        let intensity: Double
        let slowdown: Double
    }

    private enum Paint {
        case still(Color, Double)
        case glint(Motion), comet(Motion), aurora(Motion)
        case breathe(Color, period: Double, low: Double, high: Double)

        var animates: Bool {
            if case .still = self { return false }
            return true
        }
    }

    private func styled(_ motion: Motion) -> Paint? {
        switch style {
        case .off: nil
        case .glint: .glint(motion)
        case .comet: .comet(motion)
        case .aurora: .aurora(motion)
        case .breathe: .breathe(
            Color(motion.color), period: M.workingBreathePeriod * motion.slowdown,
            low: M.workingLow * motion.intensity, high: M.workingHigh * motion.intensity
        )
        }
    }

    private var paint: Paint? {
        guard style != .off else { return nil }
        switch status {
        case .idle where backgroundWork != nil, .unknown where backgroundWork != nil:
            return styled(Motion(
                color: theme.palette.mauve, partner: theme.palette.blue,
                intensity: M.backgroundWorkIntensity, slowdown: M.backgroundWorkSlowdown
            ))
        case .working:
            return styled(Motion(color: theme.palette.yellow, partner: theme.palette.mauve, intensity: 1, slowdown: 1))
        case .blocked: return .breathe(theme.red, period: M.blockedPeriod, low: M.blockedLow, high: M.blockedHigh)
        case .done: return .still(theme.teal, M.doneOpacity)
        case .idle: return .still(theme.green, M.idleOpacity)
        case .unknown: return nil
        }
    }

    private var lineHeight: CGFloat {
        if case .comet = paint { return M.cometHeight }
        return M.height
    }

    var body: some View {
        Group {
            if let paint {
                if paint.animates {
                    TimelineView(.animation(minimumInterval: M.frameInterval)) { context in
                        stack(paint, t: context.date.timeIntervalSinceReferenceDate)
                    }
                } else {
                    stack(paint, t: 0)
                }
            }
        }
        .allowsHitTesting(false)
        .help(backgroundWork ?? status.rawValue)
    }

    private func stack(_ paint: Paint, t: Double) -> some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                fill(paint, t: t, width: proxy.size.width)
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .white.opacity(M.washMidpoint), location: 0.7),
                                .init(color: .white, location: 1),
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .opacity(M.washStrength)
                    .frame(height: M.washHeight)
                fill(paint, t: t, width: proxy.size.width)
                    .frame(height: lineHeight)
                    .overlay(alignment: .leading) {
                        if case .comet(let motion) = paint {
                            cometHead(motion, t: t, width: proxy.size.width)
                        }
                    }
            }
        }
        .frame(height: M.washHeight + lineHeight)
    }

    /// Where a comet's head is (0 at the leading edge, 1 at the trailing) and
    /// how visible the whole comet is: it eases in, dims out before the far
    /// edge, and rests between passes.
    private func cometFlight(_ motion: Motion, t: Double) -> (head: Double, envelope: Double) {
        let phase = fraction(t / (M.cometPeriod * motion.slowdown)) / M.cometTravelShare
        guard phase < 1 else { return (0, 0) }
        let head = phase * M.cometReach
        let envelope = min(smoothstep(0, M.cometFadeIn, head), 1 - smoothstep(M.cometFadeOutStart, M.cometReach, head))
        return (head, envelope)
    }

    private func cometHead(_ motion: Motion, t: Double, width: CGFloat) -> some View {
        let flight = cometFlight(motion, t: t)
        let color = Color(motion.color)
        let size = M.cometHeadSize
        return Circle()
            .fill(
                RadialGradient(
                    stops: [
                        .init(color: Color.white.opacity(0.9 * motion.intensity), location: 0),
                        .init(color: color.opacity(motion.intensity), location: 0.3),
                        .init(color: color.opacity(0.25 * motion.intensity), location: 0.6),
                        .init(color: color.opacity(0), location: 1),
                    ],
                    center: .center, startRadius: 0, endRadius: size / 2
                )
            )
            .frame(width: size, height: size)
            .offset(x: width * flight.head - size / 2)
            .opacity(flight.envelope)
    }

    private func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    @ViewBuilder
    private func fill(_ paint: Paint, t: Double, width: CGFloat) -> some View {
        switch paint {
        case .still(let color, let opacity): color.opacity(opacity)
        case .glint(let motion): glint(motion, t: t, width: width)
        case .comet(let motion): comet(motion, t: t, width: width)
        case .aurora(let motion): aurora(motion, t: t)
        case .breathe(let color, let period, let low, let high): breathe(color, t: t, period: period, low: low, high: high)
        }
    }

    private func glint(_ motion: Motion, t: Double, width: CGFloat) -> some View {
        let half = M.glintHalfWidth
        let color = Color(motion.color)
        let position = fraction(t / (M.glintPeriod * motion.slowdown)) * (1 + 2 * half) - half
        return ZStack(alignment: .leading) {
            color.opacity(M.glintRest * motion.intensity)
            LinearGradient(
                stops: [
                    .init(color: color.opacity(0), location: 0),
                    .init(color: color.opacity(M.glintPeak * motion.intensity), location: 0.5),
                    .init(color: color.opacity(0), location: 1),
                ],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(width: width * 2 * half)
            .offset(x: width * (position - half))
        }
        .frame(width: width, alignment: .leading)
    }

    /// The tail alone; the head is `cometHead`, drawn over the line only so
    /// the wash above takes the tail's glow without a stretched head.
    private func comet(_ motion: Motion, t: Double, width: CGFloat) -> some View {
        let tail = M.cometTail
        let color = Color(motion.color)
        let flight = cometFlight(motion, t: t)
        return LinearGradient(
            stops: [
                .init(color: color.opacity(0), location: 0),
                .init(color: color.opacity(0.06 * motion.intensity), location: 0.35),
                .init(color: color.opacity(0.25 * motion.intensity), location: 0.7),
                .init(color: color.opacity(0.7 * motion.intensity), location: 0.95),
                .init(color: color.opacity(motion.intensity), location: 1),
            ],
            startPoint: .leading, endPoint: .trailing
        )
        .frame(width: width * tail)
        .offset(x: width * (flight.head - tail))
        .frame(width: width, alignment: .leading)
        .opacity(flight.envelope)
    }

    private func aurora(_ motion: Motion, t: Double) -> some View {
        let clock = t / motion.slowdown
        let stops = (0...M.auroraStops).map { index -> Gradient.Stop in
            let x = Double(index) / Double(M.auroraStops)
            let hue = 0.5 + 0.5 * sin((x * 2 - clock * 0.25) * 2 * .pi)
            let glow = 0.5 + 0.5 * sin((x * 3.3 + clock * 0.17) * 2 * .pi)
            return .init(
                color: Color(motion.color.mixed(with: motion.partner, amount: hue))
                    .opacity(M.auroraOpacity * motion.intensity * (0.35 + 0.65 * glow)),
                location: x
            )
        }
        return LinearGradient(stops: stops, startPoint: .leading, endPoint: .trailing)
    }

    private func breathe(_ color: Color, t: Double, period: Double, low: Double, high: Double) -> some View {
        let wave = 0.5 + 0.5 * sin(t * 2 * .pi / period)
        return color.opacity(low + (high - low) * wave * wave)
    }

    private func fraction(_ value: Double) -> Double { value - value.rounded(.down) }
}
