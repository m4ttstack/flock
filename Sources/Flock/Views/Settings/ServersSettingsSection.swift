import FlockCore
import SwiftUI

/// Every herdr session, with Stop for a running one and Delete for a
/// stopped one. Hidden while `HERDR_SOCKET_PATH` fixes the server.
struct ServersSettingsSection: View {
    let picker: ServerPicker
    let profiles: ProfileStore?
    let currentSocket: String
    let heldBy: (String) -> String?
    let home: String

    private struct Pending {
        let entry: HerdrSessionEntry
        let action: HerdrServerAction

        var verb: String { action == .stop ? "Stop" : "Delete" }
    }

    @State private var pending: Pending?

    var body: some View {
        if !picker.isLocked {
            Section("Servers") {
                ForEach(picker.entries, id: \.socketPath) { entry in
                    row(entry)
                }
                if let failure = picker.failure, picker.failureIsFromServerList {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("flock.settings.servers.error")
                }
            }
            .alert(
                pending.map { "\($0.verb) “\($0.entry.name)”?" } ?? "",
                isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                presenting: pending
            ) { pending in
                Button(pending.verb, role: .destructive) { perform(pending) }
                Button("Cancel", role: .cancel) {}
            } message: { pending in
                Text(message(for: pending))
            }
        }
    }

    private func row(_ entry: HerdrSessionEntry) -> some View {
        LabeledContent {
            let action = HerdrServerActions.action(for: entry, currentSocket: currentSocket, home: home, heldBy: heldBy)
            switch action {
            case .stop, .delete:
                Button(action == .stop ? "Stop" : "Delete") { pending = Pending(entry: entry, action: action) }
                    .disabled(picker.isBusy)
                    .accessibilityIdentifier("flock.settings.servers.\(action == .stop ? "stop" : "delete").\(entry.name)")
            case .unavailable(let reason):
                Text(reason)
                    .foregroundStyle(.secondary)
            }
        } label: {
            HStack(spacing: 6) {
                Text(entry.name)
                Text(entry.isRunning ? "running" : "stopped")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func message(for pending: Pending) -> String {
        guard pending.action == .delete else { return "Every pane and agent on it closes. This can't be undone." }
        let socket = HerdrServerAddress.normalize(pending.entry.socketPath, home: home)
        let users = (profiles?.profiles ?? []).filter {
            HerdrServerAddress.normalize(profiles?.socketPath(of: $0) ?? "", home: home) == socket
        }
        let base = "Its saved workspaces go. This can't be undone."
        return users.isEmpty ? base : base + " Used by \(users.map(\.name).joined(separator: ", "))."
    }

    private func perform(_ pending: Pending) {
        let name = pending.entry.name
        Task {
            if pending.action == .stop {
                await picker.stopServer(name: name)
            } else {
                await picker.deleteServer(name: name)
            }
        }
    }
}
