import FlockCore
import SwiftUI

/// The line under a pane's header that carries its agent's status
/// (`PaneStatusLineStyle`). Only a working or blocked pane animates, and only
/// while it is in that state, so a canvas of idle shells costs nothing.
struct PaneStatusLine: View {
    let theme: Theme
    let status: AgentStatus
    let style: PaneStatusLineStyle
    /// What a pane whose agent rests is still running (a shell job, say),
    /// which outranks the resting line as the header dot it replaces did.
    var backgroundWork: String? = nil

    private typealias M = ChromeMetrics.Pane.StatusLine

    var body: some View {
        Group {
            if style == .off {
                EmptyView()
            } else {
                switch status {
                case .idle where backgroundWork != nil, .unknown where backgroundWork != nil:
                    theme.backgroundWorkColor.opacity(M.backgroundWorkOpacity).frame(height: M.height)
                case .working: working
                case .blocked: animated { t, _ in breathe(theme.red, t: t, period: M.blockedPeriod, low: M.blockedLow, high: M.blockedHigh) }
                case .done: theme.teal.opacity(M.doneOpacity).frame(height: M.height)
                case .idle: theme.green.opacity(M.idleOpacity).frame(height: M.height)
                case .unknown: EmptyView()
                }
            }
        }
        .allowsHitTesting(false)
        .help(backgroundWork ?? status.rawValue)
    }

    @ViewBuilder
    private var working: some View {
        switch style {
        case .off: EmptyView()
        case .glint: animated { t, width in glint(t: t, width: width) }
        case .comet: animated(height: M.cometHeight) { t, width in comet(t: t, width: width) }
        case .aurora: animated { t, _ in aurora(t: t) }
        case .breathe: animated { t, _ in breathe(theme.yellow, t: t, period: M.workingBreathePeriod, low: M.workingLow, high: M.workingHigh) }
        }
    }

    private func animated<Content: View>(
        height: CGFloat = M.height, @ViewBuilder _ content: @escaping (Double, CGFloat) -> Content
    ) -> some View {
        TimelineView(.animation(minimumInterval: M.frameInterval)) { context in
            GeometryReader { proxy in
                content(context.date.timeIntervalSinceReferenceDate, proxy.size.width)
            }
        }
        .frame(height: height)
        .clipped()
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
        .frame(maxWidth: .infinity, alignment: .leading)
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
