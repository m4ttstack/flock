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

    static func open(_ url: URL, session: @escaping @MainActor () -> FlockSession, board: BoardStore) {
        guard FlockOpenLink.isOpenLink(url) else { return }
        NSApp.activate()
        NSApp.windows.first { FlockWindow.isContent($0) }?.makeKeyAndOrderFront(nil)
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
            let pins = viewModel.pins.pins
            let pin = await Task.detached {
                FlockOpenPinMatch.pin(for: link.repo, in: pins, commonDir: FlockOpenPinMatch.gitCommonDir)
            }.value
            await viewModel.openLink(link, pin: pin, board: board.names)
        }
    }
}
