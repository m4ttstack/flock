import PaddockCore
import SwiftUI

/// An agent status dot: the resting label color while the agent is idle or
/// unknown, and herdr's status hue while it is working (yellow), blocked (red)
/// or done (teal).
struct StatusDot: View {
    let status: AgentStatus
    let theme: Theme
    var size: CGFloat = 5

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
    }

    private var color: Color {
        switch status {
        case .working: theme.yellow
        case .blocked: theme.red
        case .done: theme.teal
        case .idle, .unknown: theme.textLabel
        }
    }
}
