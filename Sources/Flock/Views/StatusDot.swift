import FlockCore
import SwiftUI

extension Theme {
    /// herdr's status hue for an active agent: working yellow, blocked red,
    /// done teal. `nil` while idle or unknown, which every status mark shows
    /// in its own resting way.
    func agentStatusColor(_ status: AgentStatus) -> Color? {
        switch status {
        case .working: yellow
        case .blocked: red
        case .done: teal
        case .idle, .unknown: nil
        }
    }

    /// The hue every status mark draws with, resting states included: idle is
    /// green and unknown is the overlay, they simply draw a quieter shape.
    func agentStatusMarkColor(_ status: AgentStatus) -> Color {
        switch status {
        case .working: yellow
        case .blocked: red
        case .done: teal
        case .idle: green
        case .unknown: overlay0
        }
    }
}

/// An agent status mark, in herdr's dots style: working, blocked and done are
/// filled, idle is a hollow ring, unknown is a small centered dot. One
/// drawing rule for the rail, the strip, the grid, the hover card and the
/// attention stack, so no two surfaces can disagree about what a status looks
/// like. Herdglass reaches the same one-place rule (`StatusStyle` plus a
/// single `StatusDotView`); it fills every state but unknown because it
/// replaces the herdr TUI, while flock sits beside it and has to read the
/// same way the TUI next to it does.
struct StatusDot: View {
    let status: AgentStatus
    let theme: Theme
    var size: CGFloat = ChromeMetrics.Tab.statusDot

    var body: some View {
        ZStack {
            switch status {
            case .working, .blocked, .done:
                Circle().fill(theme.agentStatusMarkColor(status))
            case .idle:
                // Stroked inside the frame, so a ring and a fill of the same
                // size occupy exactly the same box and rows stay aligned.
                Circle()
                    .strokeBorder(theme.agentStatusMarkColor(status), lineWidth: size * ChromeMetrics.statusRingStrokeRatio)
            case .unknown:
                Circle()
                    .fill(theme.agentStatusMarkColor(status))
                    .frame(width: size * ChromeMetrics.statusUnknownRatio, height: size * ChromeMetrics.statusUnknownRatio)
            }
        }
        .frame(width: size, height: size)
    }
}
