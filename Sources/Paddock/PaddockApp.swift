import Foundation
import PaddockCore
import SwiftUI

struct PaddockApp: App {
    @State private var themeStore = ThemeStore()
    @State private var herdrStore: HerdrStore
    @State private var viewModel: SessionViewModel

    private let sessionLabel: String

    init() {
        let socketPath = Self.resolveSocketPath()
        _herdrStore = State(initialValue: HerdrStore(socketPath: socketPath))
        // Absent only when no herdr binary resolves at all (no HERDR_BIN,
        // none on PATH): panes then stay in status-card mode with no live
        // attach, rather than the app failing to launch.
        let observeAttacher = try? ObserveSupervisor(socketPath: socketPath)
        _viewModel = State(initialValue: SessionViewModel(
            client: HerdrClient(socketPath: socketPath),
            observeAttacher: observeAttacher
        ))
        sessionLabel = Self.sessionLabel(fromSocketPath: socketPath)
    }

    var body: some Scene {
        WindowGroup("Paddock") {
            MainWindow(viewModel: viewModel, sessionLabel: sessionLabel)
                .environment(themeStore)
                .task { await herdrStore.start() }
                .onChange(of: herdrStore.model) {
                    viewModel.update(model: herdrStore.model, connection: herdrStore.connection)
                }
                .onChange(of: herdrStore.connection) {
                    viewModel.update(model: herdrStore.model, connection: herdrStore.connection)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .sidebar) {
                ThemeMenu(themeStore: themeStore)
            }
        }
    }

    private static func resolveSocketPath() -> String {
        let env = ProcessInfo.processInfo.environment
        if let override = env["HERDR_SOCKET_PATH"], !override.isEmpty {
            return override
        }
        return NSHomeDirectory() + "/.config/herdr/herdr.sock"
    }

    /// `.../sessions/<name>/herdr.sock` -> `<name>`; the default socket's
    /// parent directory is `herdr` itself, shown as "default".
    private static func sessionLabel(fromSocketPath socketPath: String) -> String {
        let parent = URL(fileURLWithPath: socketPath).deletingLastPathComponent().lastPathComponent
        guard parent != "herdr" else { return "default" }
        return parent
    }
}
