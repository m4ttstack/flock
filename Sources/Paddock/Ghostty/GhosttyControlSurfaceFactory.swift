import Foundation
import PaddockCore

/// Adapts `GhosttyHost` to `SessionViewModel`'s renderer-agnostic
/// `GhosttyPaneFactory` seam: builds the bridge's argv (this same app
/// binary, re-invoked with `--bridge <pane> --socket <path>`, per
/// `Sources/Paddock/main.swift`'s dispatch) and asks the host for a session.
///
/// `--herdr-bin` is passed only when `PADDOCK_HERDR_BIN` is set, so a scratch
/// run can point the bridge at a patched herdr while the installed one stays
/// the default: absent it, the bridge inherits this app's environment and
/// falls back to its own `HERDR_BIN`/`PATH` resolution
/// (`ControlBridge.resolveHerdrBinary`).
@MainActor
final class GhosttyControlSurfaceFactory: GhosttyPaneFactory {
    private let host: GhosttyHost
    private let socketPath: String
    private let herdrBinaryOverride: String?
    private let themeColors: () -> GhosttyThemeColors
    /// Read once, at surface creation, the same way `themeColors` is: a later
    /// text-size change flows through `GhosttySession.updateAppearance`, not
    /// back through a fresh `Launch`.
    private let terminalTextSize: () -> TerminalTextSize

    init(
        host: GhosttyHost, socketPath: String,
        herdrBinaryOverride: String? = ProcessInfo.processInfo.environment["PADDOCK_HERDR_BIN"],
        themeColors: @escaping () -> GhosttyThemeColors,
        terminalTextSize: @escaping () -> TerminalTextSize
    ) {
        self.host = host
        self.socketPath = socketPath
        self.herdrBinaryOverride = (herdrBinaryOverride?.isEmpty == false) ? herdrBinaryOverride : nil
        self.themeColors = themeColors
        self.terminalTextSize = terminalTextSize
    }

    func makeSurface(
        for pane: PaneID, cols: Int, rows: Int, onUserInput: @escaping () -> Void,
        onScreenActivity: @escaping (Int) -> Bool
    ) async -> any GhosttyPaneSurface {
        // `nil` when the FIFO cannot be created (`PaneControlChannel.init?`'s
        // documented failure case): the bridge then never learns to switch
        // modes and stays observe-only -- unable to ever become the
        // control-mode (typeable) pane -- for its whole life. Logged, not
        // silently degraded: a pane that can never take real keyboard input
        // is a user-visible defect, not a cosmetic one.
        let channel = PaneControlChannel()
        if channel == nil {
            FileHandle.standardError.write(Data("paddock: failed to create control channel for pane \(pane.rawValue); it will never accept keyboard input\n".utf8))
        }
        // `nil` (`PaneStatusChannel.init?` failing) is graceful, unlike a nil
        // control channel: the pane simply never learns its mouse-capture
        // state, so every click takes the selection path -- the
        // pre-passthrough behavior -- rather than losing input entirely.
        let statusChannel = PaneStatusChannel()
        if statusChannel == nil {
            FileHandle.standardError.write(Data("paddock: failed to create status channel for pane \(pane.rawValue); mouse passthrough disabled for it\n".utf8))
        }
        let argv = BridgeOptions.argv(
            executablePath: Bundle.main.executablePath ?? CommandLine.arguments[0],
            target: pane.rawValue,
            cols: cols,
            rows: rows,
            socketPath: socketPath,
            herdrBinary: herdrBinaryOverride,
            controlPipe: channel?.path,
            statusPipe: statusChannel?.path
        )
        let session = host.makeSession(
            paneID: pane,
            configuration: .init(commandArgv: argv, themeColors: themeColors(), textSize: terminalTextSize())
        )
        session.onUserInput = onUserInput
        session.onScreenActivity = onScreenActivity
        session.controlChannel = channel
        session.statusChannel = statusChannel
        // Read on the main queue and apply synchronously: a capture line's
        // effect lands in the order the bridge wrote it, so an app toggling
        // mouse mode off then on can never end up applied on->off.
        statusChannel?.start(
            queue: .main,
            onFirstFrame: { [weak session] in
                MainActor.assumeIsolated {
                    session?.markFirstFrameReceived()
                }
            }
        ) { [weak session] enabled, _ in
            MainActor.assumeIsolated {
                session?.setMouseCapture(enabled: enabled)
            }
        }
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

    /// Drops paddock's only strong reference to the session, AND -- since
    /// `GhosttySession.view` now holds its own view strongly, so a parked
    /// pane's surface survives its cell disappearing from SwiftUI -- breaks
    /// that retain cycle explicitly, by nilling `session.view` out. Without
    /// this, `session` and its view would keep each other alive forever
    /// once nothing outside the pair references either: `GhosttySurfaceView
    /// .session` is itself a strong reference back. Removing the view from
    /// its superview first is defensive; SwiftUI has ordinarily already done
    /// so by the time a pane's surface is torn down for real (the warm cap's
    /// eviction, or herdr closing the pane), both of which only ever reach a
    /// pane that is already parked -- long since removed from any window.
    func detach() async {
        session.view?.removeFromSuperview()
        session.view = nil
    }

    func setMode(_ mode: PaneMode) async {
        session.setPaneMode(mode)
    }

    func park() {
        session.setOccluded(true)
    }

    func unpark() {
        session.setOccluded(false)
    }

    var hasFirstFrame: Bool { session.hasFirstFrame }
}
