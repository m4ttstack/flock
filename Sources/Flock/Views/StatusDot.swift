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
///
/// A pane herdr calls idle or done that is still running background work
/// draws `BackgroundMarkView` instead, whatever `status` says.
struct StatusDot: View {
    let status: AgentStatus
    let theme: Theme
    var size: CGFloat = ChromeMetrics.Tab.statusDot
    var isBackground = false

    init(status: AgentStatus, theme: Theme, size: CGFloat = ChromeMetrics.Tab.statusDot, isBackground: Bool = false) {
        self.status = status
        self.theme = theme
        self.size = size
        self.isBackground = isBackground
    }

    init(shown: ShownStatus, theme: Theme, size: CGFloat = ChromeMetrics.Tab.statusDot) {
        self.init(status: shown.status, theme: theme, size: size, isBackground: shown.isBackground)
    }

    private var color: Color { theme.agentStatusMarkColor(status) }

    var body: some View {
        ZStack {
            switch status {
            case _ where isBackground:
                BackgroundMarkView(theme: theme, size: size)
            case .working, .blocked, .done:
                Circle().fill(color)
            case .idle:
                // Stroked inside the frame, so a ring and a fill of the same
                // size occupy exactly the same box and rows stay aligned.
                Circle()
                    .strokeBorder(color, lineWidth: size * ChromeMetrics.statusRingStrokeRatio)
            case .unknown:
                Circle()
                    .fill(color)
                    .frame(width: size * ChromeMetrics.statusUnknownRatio, height: size * ChromeMetrics.statusUnknownRatio)
            }
        }
        .frame(width: size, height: size)
    }
}

/// A pane busy only in the background: idle's ring, in mauve, so it reads as
/// neither idle nor working.
struct BackgroundMarkView: View {
    let theme: Theme
    let size: CGFloat

    var body: some View {
        Circle()
            .strokeBorder(theme.backgroundWorkColor, lineWidth: size * ChromeMetrics.statusRingStrokeRatio)
            .frame(width: size, height: size)
    }
}

extension Theme {
    var backgroundWorkColor: Color { mauve }

    /// The colour a status's text and marks take as flock shows it.
    func shownStatusColor(_ shown: ShownStatus) -> Color {
        shown.isBackground ? backgroundWorkColor : agentStatusMarkColor(shown.status)
    }
}
