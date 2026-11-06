import AppKit
import FlockCore
import Foundation

/// Takes a `flock://open` link from Launch Services, brings the window
/// forward, and hands the checked link to the session.
@MainActor
enum FlockLinkOpener {
    /// A link can arrive on a cold launch, before herdr's first snapshot.
    private static let snapshotWait: Duration = .seconds(15)
    private static let snapshotPoll: Duration = .milliseconds(200)
    private static let launchPoll: Duration = .milliseconds(50)

    /// False until the app delegate's launch is over. A link that started the
    /// app arrives in that stretch.
    static var launchFinished = false

    static func open(_ url: URL, session: @escaping @MainActor () -> FlockSession, board: BoardStore) {
        guard FlockOpenLink.isOpenLink(url) else { return }
        NSApp.activate()
        if launchFinished {
            showMainWindow()
        } else {
            // A reopen sent while the app is still launching can race the
            // launch into a second window, so it waits the launch out.
            Task {
                while !launchFinished { try? await Task.sleep(for: launchPoll) }
                showMainWindow()
            }
        }
        Task {
            let home = NSHomeDirectory()
            let token = await Task.detached { FlockOpenToken.readOrCreate(home: home) }.value
            let parsed = FlockOpenLink.parse(url, expectedToken: token, isFolder: SessionViewModel.directoryExists)
            guard case .success(let link) = parsed else {
                if case .failure(let refusal) = parsed { session().toastCenter.show(refusal.message, kind: .info) }
                return
            }
            if board.names == nil { await board.refresh() }
            let viewModel = session().viewModel
            let deadline = ContinuousClock.now + snapshotWait
            while viewModel.userModel == nil, ContinuousClock.now < deadline {
                try? await Task.sleep(for: snapshotPoll)
            }
            guard viewModel.userModel != nil else {
                session().toastCenter.show("Flock isn't connected to herdr, so \(link.label) didn't open.", kind: .info)
                return
            }
            guard !viewModel.isRemoteMachine else {
                await viewModel.openLink(link, pin: nil, board: nil)
                return
            }
            let pins = viewModel.pins.pins
            let pin = await Task.detached {
                FlockOpenPinMatch.pin(for: link.repo, in: pins, commonDir: FlockOpenPinMatch.gitCommonDir)
            }.value
            await viewModel.openLink(link, pin: pin, board: board.names)
        }
    }

    /// The scene claims no URL (see `FlockApp`), so a link that finds no
    /// window, closed or never made because the link started the app, has
    /// to ask for it the way a Dock click does: opening the running app's
    /// own bundle sends it a reopen, and SwiftUI answers with its window. A
    /// closed window can still sit in `FlockWindow.content`, so being there
    /// is not being open.
    private static func showMainWindow() {
        if let window = FlockWindow.content, window.isVisible || window.isMiniaturized {
            window.makeKeyAndOrderFront(nil)
        } else {
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}
