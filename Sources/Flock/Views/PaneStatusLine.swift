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

    private enum Paint {
        case still(Color, Double)
        case glint, comet, aurora
        case breathe(Color, period: Double, low: Double, high: Double)

        var animates: Bool {
            if case .still = self { return false }
            return true
        }
    }

    private var paint: Paint? {
        guard style != .off else { return nil }
        switch status {
        case .idle where backgroundWork != nil, .unknown where backgroundWork != nil:
            return .still(theme.backgroundWorkColor, M.backgroundWorkOpacity)
        case .working:
            switch style {
            case .off: return nil
            case .glint: return .glint
            case .comet: return .comet
            case .aurora: return .aurora
            case .breathe: return .breathe(theme.yellow, period: M.workingBreathePeriod, low: M.workingLow, high: M.workingHigh)
            }
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
            }
        }
        .frame(height: M.washHeight + lineHeight)
        .clipped()
    }

    @ViewBuilder
    private func fill(_ paint: Paint, t: Double, width: CGFloat) -> some View {
        switch paint {
        case .still(let color, let opacity): color.opacity(opacity)
        case .glint: glint(t: t, width: width)
        case .comet: comet(t: t, width: width)
        case .aurora: aurora(t: t)
        case .breathe(let color, let period, let low, let high): breathe(color, t: t, period: period, low: low, high: high)
        }
    }

    private func glint(t: Double, width: CGFloat) -> some View {
        let half = M.glintHalfWidth
        let position = fraction(t / M.glintPeriod) * (1 + 2 * half) - half
        return ZStack(alignment: .leading) {
            theme.yellow.opacity(M.glintRest)
            LinearGradient(
                stops: [
                    .init(color: theme.yellow.opacity(0), location: 0),
                    .init(color: theme.yellow.opacity(M.glintPeak), location: 0.5),
                    .init(color: theme.yellow.opacity(0), location: 1),
                ],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(width: width * 2 * half)
            .offset(x: width * (position - half))
        }
        .frame(width: width, alignment: .leading)
    }

    private func comet(t: Double, width: CGFloat) -> some View {
        let tail = M.cometTail
        let head = fraction(t / M.cometPeriod) * (1 + tail)
        return LinearGradient(
            stops: [
                .init(color: theme.yellow.opacity(0), location: 0),
                .init(color: theme.yellow.opacity(0.12), location: 0.5),
                .init(color: theme.yellow.opacity(0.5), location: 0.8),
                .init(color: theme.yellow, location: 1),
            ],
            startPoint: .leading, endPoint: .trailing
        )
        .frame(width: width * tail)
        .offset(x: width * (head - tail))
        .frame(width: width, alignment: .leading)
    }

    private func aurora(t: Double) -> some View {
        let from = theme.palette.yellow
        let to = theme.palette.mauve
        let stops = (0...M.auroraStops).map { index -> Gradient.Stop in
            let x = Double(index) / Double(M.auroraStops)
            let hue = 0.5 + 0.5 * sin((x * 2 - t * 0.25) * 2 * .pi)
            let glow = 0.5 + 0.5 * sin((x * 3.3 + t * 0.17) * 2 * .pi)
            return .init(
                color: Color(from.mixed(with: to, amount: hue)).opacity(M.auroraOpacity * (0.35 + 0.65 * glow)),
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
