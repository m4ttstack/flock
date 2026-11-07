import FlockCore
import Observation
import SwiftUI

/// A status every pane's status line shows in place of its own, so each state
/// can be judged side by side. Flock Dev only; nothing reaches herdr.
enum ForcedPaneStatus: String, CaseIterable {
    case working, blocked, done, idle, backgroundWork

    var title: String {
        switch self {
        case .working: "Working"
        case .blocked: "Blocked"
        case .done: "Done"
        case .idle: "Idle"
        case .backgroundWork: "Background work"
        }
    }

    var agentStatus: AgentStatus {
        switch self {
        case .working: .working
        case .blocked: .blocked
        case .done: .done
        case .idle, .backgroundWork: .idle
        }
    }
}

/// One per process: a dev tool, not session state, so it is not threaded
/// through the environment.
@MainActor
@Observable
final class DevStatusOverride {
    static let shared = DevStatusOverride()

    var forced: ForcedPaneStatus?

    func status(for pane: PaneRecord) -> AgentStatus {
        forced?.agentStatus ?? pane.agentStatus
    }

    func backgroundWork(real: String?) -> String? {
        guard let forced else { return real }
        return forced == .backgroundWork ? "background work (forced)" : nil
    }
}

/// The DEV tag as a menu that forces every pane's status.
struct DevStatusMenu: View {
    let theme: Theme
    @State private var override = DevStatusOverride.shared

    var body: some View {
        Menu {
            Section("Force pane status") {
                Button { override.forced = nil } label: {
                    if override.forced == nil { Label("Real status", systemImage: "checkmark") } else { Text("Real status") }
                }
                ForEach(ForcedPaneStatus.allCases, id: \.self) { status in
                    Button { override.forced = status } label: {
                        if override.forced == status {
                            Label(status.title, systemImage: "checkmark")
                        } else {
                            Text(status.title)
                        }
                    }
                }
            }
        } label: {
            DevTag(theme: theme, suffix: override.forced?.title)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Force every pane's status")
    }
}
