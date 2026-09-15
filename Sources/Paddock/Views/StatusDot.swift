import PaddockCore
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
}

/// An agent status dot: its status hue while the agent is active, the resting
/// label color while it is idle or unknown.
struct StatusDot: View {
    let status: AgentStatus
    let theme: Theme
    var size: CGFloat = ChromeMetrics.Tab.statusDot

    var body: some View {
        Circle()
            .fill(theme.agentStatusColor(status) ?? theme.textLabel)
            .frame(width: size, height: size)
    }
}
