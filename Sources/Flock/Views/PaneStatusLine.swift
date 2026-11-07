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

    /// One pass of the comet: it crosses to the trailing edge, bursts there,
    /// then rests. `head` runs 0 at the leading edge to 1 at the trailing;
    /// `burst` is the impact's progress, nil until the head arrives.
    private struct CometFlight {
        var head: Double
        var envelope: Double
        var burst: Double?
        /// Which pass this is, so each burst throws its own sparks.
        var pass: Int = 0
    }

    private func cometFlight(_ motion: Motion, t: Double) -> CometFlight {
        let cycles = t / (M.cometPeriod * motion.slowdown)
        let phase = fraction(cycles)
        let pass = Int(cycles.rounded(.down).truncatingRemainder(dividingBy: 100_000))
        if phase < M.cometTravelShare {
            let head = pow(phase / M.cometTravelShare, M.cometAcceleration)
            return CometFlight(head: head, envelope: smoothstep(0, M.cometFadeIn, head), burst: nil)
        }
        let burst = (phase - M.cometTravelShare) / M.cometBurstShare
        guard burst < 1 else { return CometFlight(head: 1, envelope: 0, burst: nil) }
        return CometFlight(head: 1, envelope: 1 - smoothstep(0, M.cometTailRetract, burst), burst: burst, pass: pass)
    }

    @ViewBuilder
    private func cometHead(_ motion: Motion, t: Double, width: CGFloat) -> some View {
        let flight = cometFlight(motion, t: t)
        let size = M.cometHeadSize
        if let burst = flight.burst {
            cometBurst(motion, progress: burst, pass: flight.pass, seconds: burst * M.cometPeriod * motion.slowdown * M.cometBurstShare)
                .offset(x: width - M.cometBurstCanvas / 2 - size / 2)
        } else {
            Circle()
                .fill(headGlow(motion, radius: size / 2))
                .frame(width: size, height: size)
                .offset(x: min(width * flight.head, width - size / 2) - size / 2)
                .opacity(flight.envelope)
        }
    }

    private func headGlow(_ motion: Motion, radius: CGFloat) -> RadialGradient {
        let color = Color(motion.color)
        return RadialGradient(
            stops: [
                .init(color: Color.white.opacity(0.9 * motion.intensity), location: 0),
                .init(color: color.opacity(motion.intensity), location: 0.3),
                .init(color: color.opacity(0.25 * motion.intensity), location: 0.6),
                .init(color: color.opacity(0), location: 1),
            ],
            center: .center, startRadius: 0, endRadius: radius
        )
    }

    /// The impact: a flash where the head struck, and sparks thrown back off
    /// the wall that gravity pulls down into the pane as they fade. Every
    /// spark's speed, angle, size and life come from the pass number, so no
    /// two bursts match and each one holds still frame to frame.
    private func cometBurst(_ motion: Motion, progress: Double, pass: Int, seconds: Double) -> some View {
        let color = Color(motion.color)
        let flashSize = M.cometHeadSize * 2
        return ZStack {
            Circle()
                .fill(headGlow(motion, radius: M.cometHeadSize))
                .frame(width: flashSize, height: flashSize)
                .scaleEffect(1 + 0.5 * (1 - pow(1 - progress, 3)))
                .opacity(max(0, 1 - progress * 3))
            ForEach(0..<M.cometSparkCount, id: \.self) { index in
                let spark = Spark(pass: pass, index: index)
                let life = min(1, progress / spark.life)
                let x = spark.velocity.dx * seconds
                let y = spark.velocity.dy * seconds + 0.5 * M.cometGravity * seconds * seconds
                Circle()
                    .fill(spark.isWhite ? Color.white.opacity(0.85 * motion.intensity) : color.opacity(motion.intensity))
                    .frame(width: spark.size, height: spark.size)
                    .offset(x: x, y: y)
                    .opacity(life < 1 ? 1 - pow(life, 2.5) : 0)
            }
        }
        .frame(width: M.cometBurstCanvas, height: M.cometBurstCanvas)
    }

    /// One spark of a burst, drawn from a hash of its pass and index.
    private struct Spark {
        let velocity: CGVector
        let size: CGFloat
        let life: Double
        let isWhite: Bool

        init(pass: Int, index: Int) {
            func noise(_ salt: Double) -> Double {
                let v = sin(Double(pass) * 12.9898 + Double(index) * 78.233 + salt * 37.719) * 43758.5453
                return v - v.rounded(.down)
            }
            typealias M = ChromeMetrics.Pane.StatusLine
            let angle = (M.cometSparkSpread.lowerBound + noise(1) * (M.cometSparkSpread.upperBound - M.cometSparkSpread.lowerBound)) * .pi / 180
            let speed = M.cometSparkSpeed.lowerBound + noise(2) * (M.cometSparkSpeed.upperBound - M.cometSparkSpeed.lowerBound)
            velocity = CGVector(dx: cos(angle) * speed, dy: sin(angle) * speed)
            size = M.cometSparkSize.lowerBound + noise(3) * (M.cometSparkSize.upperBound - M.cometSparkSize.lowerBound)
            life = 0.55 + noise(4) * 0.45
            isWhite = noise(5) < 0.3
        }
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
        case .breathe(let color, let period, let low, let high):
            breathe(color, t: t, width: width, period: period, low: low, high: high)
        }
    }

    private func glint(_ motion: Motion, t: Double, width: CGFloat) -> some View {
        let half = M.glintHalfWidth
        let color = Color(motion.color)
        // Right and back again on a cosine, so it eases into each turn.
        let position = 0.5 - 0.5 * cos(2 * .pi * t / (M.glintPeriod * motion.slowdown))
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

    /// Brightens and widens together from the centre, its ends feathered so
    /// the line's reach is never a hard edge.
    private func breathe(_ color: Color, t: Double, width: CGFloat, period: Double, low: Double, high: Double) -> some View {
        let wave = 0.5 + 0.5 * sin(t * 2 * .pi / period)
        let span = M.breatheNarrowest + (1 - M.breatheNarrowest) * wave
        let shown = color.opacity(low + (high - low) * wave * wave)
        return LinearGradient(
            stops: [
                .init(color: shown.opacity(0), location: 0),
                .init(color: shown, location: M.breatheFeather),
                .init(color: shown, location: 1 - M.breatheFeather),
                .init(color: shown.opacity(0), location: 1),
            ],
            startPoint: .leading, endPoint: .trailing
        )
        .frame(width: width * span)
        .frame(width: width)
    }

    private func fraction(_ value: Double) -> Double { value - value.rounded(.down) }
}
