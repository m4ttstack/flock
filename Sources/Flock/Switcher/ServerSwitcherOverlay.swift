import FlockCore
import SwiftUI

/// ⌥`'s herdr servers, over the whole window below the title bar: a change
/// replaces everything the window shows, as a profile switch does. Reads
/// Settings' Server picker, so both offer the same servers from one listing,
/// and opens through it, so a change takes the path Settings takes.
struct ServerSwitcherOverlay: View {
    let theme: Theme
    let switcher: ServerSwitcher
    let picker: ServerPicker
    /// False on a machine profile, whose server herdr fixes, and under a
    /// socket override.
    let canChangeServer: Bool
    let currentSocket: () -> String
    let blocked: () -> Bool

    var body: some View {
        SwitcherView(
            theme: theme, switcher: switcher, trigger: .optionBacktick, accessibilityPrefix: "flock.serverSwitcher",
            heading: "Servers",
            row: { [picker, currentSocket] id in
                .server(ServerSwitcherRow.make(id, entries: picker.entries, currentSocket: currentSocket(), home: picker.home))
            },
            candidates: { [picker, canChangeServer, currentSocket] in
                // The press is answered from the last listing; this one is
                // for the rows' state and the next press.
                if canChangeServer { Task { await picker.refresh() } }
                return ServerSwitcher.candidates(
                    picker.hasListed ? picker.entries : nil, currentSocket: currentSocket(), home: picker.home,
                    canChangeServer: canChangeServer
                )
            },
            current: { [picker, currentSocket] in ServerID(socketPath: currentSocket(), home: picker.home) },
            blocked: blocked,
            go: { [picker] id in
                guard let entry = picker.entries.first(where: { ServerID(socketPath: $0.socketPath, home: picker.home) == id })
                else { return }
                Task { await picker.choose(entry) }
            }
        )
        .padding(.top, ChromeMetrics.TitleBar.height)
        // A first press with nothing listed yet passes through, so the list
        // is read ahead of it.
        .task {
            guard canChangeServer, !picker.hasListed else { return }
            await picker.refresh()
        }
    }
}
