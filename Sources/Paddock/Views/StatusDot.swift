import PaddockCore
import SwiftUI

/// One dot, four surfaces (pane header, tab pill, workspace row, All
/// Workspaces grid): filled for working/blocked/done, a hollow ring for
/// idle, and a small centered dot for unknown. Colors come from the active
/// theme; herdr's mapping is Global Constraints-fixed (working=yellow,
/// blocked=red, done=teal, idle=green, unknown=overlay0).
struct StatusDot: View {
    let status: AgentStatus
    let theme: Theme
    var size: CGFloat = 8

    var body: some View {
        Group {
            switch status {
            case .idle:
                Circle()
                    .strokeBorder(theme.green, lineWidth: 1.5)
            case .working:
                Circle().fill(theme.yellow)
            case .blocked:
                Circle().fill(theme.red)
            case .done:
                Circle().fill(theme.teal)
            case .unknown:
                Circle()
                    .fill(theme.overlay0)
                    .frame(width: size * 0.4, height: size * 0.4)
            }
        }
        .frame(width: size, height: size)
    }
}
