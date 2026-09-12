import Foundation
import PaddockCore

/// Adapts `GhosttyHost` to `SessionViewModel`'s renderer-agnostic
/// `GhosttyPaneFactory` seam: builds the bridge's argv (this same app
/// binary, re-invoked with `--bridge <pane> --socket <path>`, per
/// `Sources/Paddock/main.swift`'s dispatch) and asks the host for a session.
/// `herdrBinary` is deliberately left unset: the bridge process inherits this
/// app's environment, so its own `HERDR_BIN`/`PATH` resolution
/// (`ControlBridge`'s `resolveHerdrBinary`) needs no separate lookup here.
@MainActor
final class GhosttyControlSurfaceFactory: GhosttyPaneFactory {
    private let host: GhosttyHost
    private let socketPath: String
    private let themeColors: () -> GhosttyThemeColors

    init(host: GhosttyHost, socketPath: String, themeColors: @escaping () -> GhosttyThemeColors) {
        self.host = host
        self.socketPath = socketPath
        self.themeColors = themeColors
    }

    func makeSurface(for pane: PaneID, cols: Int, rows: Int, onUserInput: @escaping () -> Void) async -> any GhosttyPaneSurface {
        // `nil` when the FIFO cannot be created (`PaneControlChannel.init?`'s
        // documented failure case): the bridge then simply never learns to
        // switch modes and stays observe-only for this pane's whole life,
        // same graceful degradation `PaneControlChannel`'s own doc comment
        // describes.
        let channel = PaneControlChannel()
        let argv = BridgeOptions.argv(
            executablePath: Bundle.main.executablePath ?? CommandLine.arguments[0],
            target: pane.rawValue,
            cols: cols,
            rows: rows,
            socketPath: socketPath,
            controlPipe: channel?.path
        )
        let session = host.makeSession(configuration: .init(commandArgv: argv, themeColors: themeColors()))
        session.onUserInput = onUserInput
        session.controlChannel = channel
        return GhosttySessionSurfaceHandle(session: session)
    }
}

/// The concrete `GhosttyPaneSurface` conformance: wraps the real
/// `GhosttySession` so `SessionViewModel` (AppKit-free) can hold one behind
/// the protocol while the view layer downcasts back to this type to reach
/// `session` for hosting the `NSView` and pushing live theme updates.
///
/// `@unchecked Sendable`: `session` is a `let`, but `GhosttySession` itself
/// is `@MainActor`-isolated and mutable -- safe here only because every
/// touch of it, from any caller, goes through this type's own `@MainActor`
/// protocol methods or the view layer's `@MainActor` downcast, never off
/// the main actor.
final class GhosttySessionSurfaceHandle: GhosttyPaneSurface, @unchecked Sendable {
    let session: GhosttySession

    init(session: GhosttySession) {
        self.session = session
    }

    /// A no-op by design: a real surface's size is driven by its NSView's
    /// own pixel layout (`GhosttySurfaceView.layout()` -> `session.resize(to:)`),
    /// never by the layout-cell cols/rows this seam is handed -- see
    /// `GhosttyPaneSurface.resize`'s doc comment. The call still reaches
    /// here (rather than being dropped from the protocol) so
    /// `SessionViewModel` has one lifecycle contract for both renderers.
    func resize(cols: Int, rows: Int) {}

    /// Drops paddock's only strong reference to the session. If nothing else
    /// still holds one (the hosting `NSView` has already been torn down, or
    /// never existed for this call), ARC frees it here, which frees the
    /// libghostty surface and ends the bridge's PTY.
    func detach() async {}

    func typeText(_ text: String) {
        session.insertText(text)
    }

    func setMode(_ mode: PaneMode) async {
        session.setPaneMode(mode)
    }
}
