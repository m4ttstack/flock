// Portions derived from Herdglass (BSL-1.1), Sources/Herdglass/Ghostty/TerminalHost.swift
// and Sources/Herdglass/GhosttyRuntime.swift (the config-loading half only;
// the window-chrome config reader in GhosttyConfig.swift is not ported here).
import AppKit
import GhosttyKit
import os
import FlockCore

/// libghostty's app handle: one per process, plus the callbacks libghostty
/// calls back into Swift with. Owns the `ghostty_app_t` and the route from a
/// surface back to its session.
///
/// Unlike Herdglass, the base config here is never loaded from a real
/// `~/.config/ghostty/config`: flock's terminal colors come from its own
/// `Theme`, not from mirroring a local Ghostty install, so the base config is
/// `ghostty_config_new()` finalized with nothing on top of it, and every
/// surface's real color/command config arrives through
/// `configureNextSurface`.
@MainActor
final class GhosttyHost {
    enum Failure: Error, LocalizedError {
        case initFailed
        case configCreationFailed
        case appCreationFailed

        var errorDescription: String? {
            switch self {
            case .initFailed: return "ghostty_init failed"
            case .configCreationFailed: return "ghostty_config_new failed"
            case .appCreationFailed: return "ghostty_app_new failed"
            }
        }
    }

    /// Read from libghostty's own threads, which is why it is not actor isolated.
    nonisolated(unsafe) private(set) var app: ghostty_app_t?

    private var sessions: [ObjectIdentifier: WeakGhosttySession] = [:]
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
    /// The config every surface's per-surface clone is cloned from. Freed
    /// only in `deinit`: `ghostty_app_update_config`/`ghostty_config_clone`
    /// both clone what they are given, so this can stay alive and unchanged
    /// for the app's whole lifetime. `nonisolated(unsafe)` solely because
    /// `deinit` is not actor-isolated; every live touch stays on the main
    /// actor (libghostty callback threads never read it, unlike `app`).
    nonisolated(unsafe) private var baseConfig: ghostty_config_t?

    /// Fired with the text just written to the system clipboard and the pane
    /// it was copied in, after the pasteboard write has happened, on the main
    /// actor: by any surface (copy-on-select's mouse-up, an explicit copy
    /// action), or by a mouse-capturing pane app caught by `appCopyWatch`.
    var onClipboardWrite: ((String, PaneID) -> Void)?

    private var appCopyWatch = PaneAppCopyWatch()
    private var appCopyPoll: Task<Void, Never>?

    /// NSPasteboard posts no change notification, so an armed watch polls
    /// the change count until it fires or lapses.
    func paneAppTookPrimaryRelease(_ paneID: PaneID) {
        appCopyWatch.arm(
            pane: paneID, changeCount: NSPasteboard.general.changeCount,
            now: ProcessInfo.processInfo.systemUptime
        )
        guard appCopyPoll == nil else { return }
        appCopyPoll = Task { [weak self] in
            while let self, self.appCopyWatch.isArmed {
                try? await Task.sleep(for: .milliseconds(100))
                let pasteboard = NSPasteboard.general
                let pane = self.appCopyWatch.observe(
                    changeCount: pasteboard.changeCount, now: ProcessInfo.processInfo.systemUptime
                )
                if let pane, let text = pasteboard.string(forType: .string), !text.isEmpty {
                    self.onClipboardWrite?(text, pane)
                }
            }
            self?.appCopyPoll = nil
        }
    }

    /// `ghostty_init` has to run before any other libghostty call, the config
    /// included, so it is separate from creating the app. Safe to call twice;
    /// only the first call reaches libghostty.
    static func initializeLibrary() -> Bool {
        if initialized { return true }
        initialized = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == 0
        return initialized
    }

    private nonisolated(unsafe) static var initialized = false

    init() throws {
        guard Self.initializeLibrary() else { throw Failure.initFailed }
        guard let config = ghostty_config_new() else { throw Failure.configCreationFailed }
        ghostty_config_finalize(config)

        var runtime = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: false,
            wakeup_cb: ghosttyHostWakeup,
            action_cb: ghosttyHostAction,
            read_clipboard_cb: ghosttyHostReadClipboard,
            confirm_read_clipboard_cb: ghosttyHostConfirmReadClipboard,
            write_clipboard_cb: ghosttyHostWriteClipboard,
            close_surface_cb: ghosttyHostCloseSurface
        )

        guard let app = ghostty_app_new(&runtime, config) else {
            ghostty_config_free(config)
            throw Failure.appCreationFailed
        }
        self.app = app
        self.baseConfig = config
        beginObservingApplicationFocus()
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        if let app {
            ghostty_app_free(app)
        }
        if let baseConfig {
            ghostty_config_free(baseConfig)
        }
    }

    func makeSession(paneID: PaneID, configuration: GhosttySession.Launch) -> GhosttySession {
        GhosttySession(host: self, paneID: paneID, configuration: configuration)
    }

    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    func register(_ session: GhosttySession) {
        sessions[ObjectIdentifier(session)] = WeakGhosttySession(value: session)
    }

    func unregister(_ session: GhosttySession) {
        sessions.removeValue(forKey: ObjectIdentifier(session))
    }

    /// Where the user's `~/.config/ghostty/config` lives, according to
    /// libghostty rather than to a guess of our own. Harmless to expose even
    /// though flock never loads that file itself: `ghostty_config_open_path`
    /// is a pure libghostty query, not tied to whatever config this app built.
    func openConfig() {
        let path = ghostty_config_open_path()
        defer { ghostty_string_free(path) }
        guard let pointer = path.ptr, path.len > 0 else { return }
        let value = String(
            decoding: UnsafeBufferPointer(start: pointer, count: Int(path.len)).map(UInt8.init(bitPattern:)),
            as: UTF8.self
        )
        NSWorkspace.shared.open(URL(fileURLWithPath: value))
    }

    /// A plain write, never an atomic one: each file is unique, private and
    /// read once straight after, so the temp-file rename an atomic write adds
    /// buys nothing, and a busy volume can hold that rename, and the main
    /// thread with it, for tens of seconds.
    private static func writeScratch(_ text: String, to file: URL) -> Bool {
        (try? text.write(to: file, atomically: false, encoding: .utf8)) != nil
    }

    /// Clones the base config, writes a scratch `.ghostty` file combining
    /// this theme's colors with the one command this surface should run, and
    /// pushes the clone onto the app -- MUST run right before this surface's
    /// `ghostty_surface_new` (see `GhosttySession.createSurface`), never
    /// batched or deferred.
    ///
    /// This is the only way a surface's child process ever differs from the
    /// login shell: `ghostty_surface_config_s` has `command`/`env_vars`
    /// fields, but libghostty silently ignores both of them at the vendored
    /// commit pinned in `Vendor/libghostty.version` -- `working_directory`,
    /// the field right before `command` in the same struct, IS honoured, and
    /// the pointer is non-null at the `ghostty_surface_new` call, so this is
    /// not a null-pointer bug on flock's side and not something a future
    /// libghostty bump is guaranteed to fix quietly. The app-config route is
    /// the one libghostty does read a command from.
    ///
    /// Safe to call once per surface, back to back, with no locking of its
    /// own: every attach that reaches here is already serialized onto the
    /// main actor (`GhosttySession.attach` runs from `NSView.viewDidMoveToWindow`),
    /// so there is never a second `configureNextSurface` in flight while this
    /// one's scratch file is still being written or read.
    @discardableResult
    func configureNextSurface(
        colors: GhosttyThemeColors, commandArgv: [String], fontFamily: String, fontSizePoints: Double,
        optionAsAlt: OptionAsAlt
    ) -> Bool {
        guard let app, let baseConfig, !commandArgv.isEmpty else { return false }
        let text = GhosttyThemeConfig.configText(
            colors: colors, commandArgv: commandArgv, fontFamily: fontFamily, fontSizePoints: fontSizePoints,
            optionAsAlt: optionAsAlt
        )
        let file = ScratchDirectory.url
            .appendingPathComponent("flock-surface-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString.prefix(8)).ghostty")
        guard Self.writeScratch(text, to: file),
              let clone = ghostty_config_clone(baseConfig)
        else { return false }
        defer {
            ghostty_config_free(clone)
            try? FileManager.default.removeItem(at: file)
        }
        // No `ghostty_config_finalize` afterwards: the clone is already
        // finalized, and loading a file is what parses and validates a key --
        // a rejected one lands in the config's diagnostics, which is the only
        // way libghostty reports it.
        let before = ghostty_config_diagnostics_count(clone)
        file.path.withCString { path in
            ghostty_config_load_file(clone, path)
        }
        guard ghostty_config_diagnostics_count(clone) == before else { return false }
        ghostty_app_update_config(app, clone)
        restoreOwnAppearance(afterPushing: colors, fontSizePoints: fontSizePoints, optionAsAlt: optionAsAlt)
        return true
    }

    /// `ghostty_app_update_config` reaches every live surface, and each one
    /// takes the pushed `font-size` as its own (`Surface.zig`'s
    /// `updateConfig`). A surface kept at another size, as the rt modal's is,
    /// gets its own appearance pushed back.
    private func restoreOwnAppearance(afterPushing colors: GhosttyThemeColors, fontSizePoints: Double, optionAsAlt: OptionAsAlt) {
        for session in liveSessions() where session.surface != nil {
            let own = session.configuration
            guard own.fontSizePoints != fontSizePoints || own.themeColors != colors || own.optionAsAlt != optionAsAlt
            else { continue }
            session.updateAppearance(own.themeColors, fontSizePoints: own.fontSizePoints, optionAsAlt: own.optionAsAlt)
        }
    }

    /// Restyles a surface that already exists, in place: same scratch-config
    /// mechanism as `configureNextSurface` (a clone of `baseConfig` loaded
    /// from a temp `.ghostty` file), but pushed via
    /// `ghostty_surface_update_config` onto the given surface instead of
    /// `ghostty_app_update_config` onto the app -- a new surface already
    /// gets its theme from `Launch.themeColors` at creation, so the app-wide
    /// config never needs to carry the live palette itself. `commandArgv`
    /// is required by `GhosttyThemeConfig.configText` but has no live effect
    /// here: `ghostty_surface_update_config` never re-runs a surface's
    /// command (see the call site's doc comment).
    @discardableResult
    func updateLiveConfig(
        surface: ghostty_surface_t, colors: GhosttyThemeColors, commandArgv: [String],
        fontFamily: String, fontSizePoints: Double, optionAsAlt: OptionAsAlt
    ) -> Bool {
        guard let baseConfig, !commandArgv.isEmpty else { return false }
        let text = GhosttyThemeConfig.configText(
            colors: colors, commandArgv: commandArgv, fontFamily: fontFamily, fontSizePoints: fontSizePoints,
            optionAsAlt: optionAsAlt
        )
        let file = ScratchDirectory.url
            .appendingPathComponent("flock-surface-update-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString.prefix(8)).ghostty")
        guard Self.writeScratch(text, to: file),
              let clone = ghostty_config_clone(baseConfig)
        else { return false }
        defer {
            ghostty_config_free(clone)
            try? FileManager.default.removeItem(at: file)
        }
        let before = ghostty_config_diagnostics_count(clone)
        file.path.withCString { path in
            ghostty_config_load_file(clone, path)
        }
        guard ghostty_config_diagnostics_count(clone) == before else { return false }
        ghostty_surface_update_config(surface, clone)
        return true
    }

    /// The sessions still alive, dropping any whose pane has gone.
    fileprivate func liveSessions() -> [GhosttySession] {
        sessions = sessions.filter { $0.value.value != nil }
        return sessions.values.compactMap(\.value)
    }

    /// A display was added, removed or reconfigured -- the one notification
    /// that reaches a pane whose OWN window never changed screen, because the
    /// window it sits in was not the one on screen when the arrangement
    /// changed. Every other scale path (`GhosttySurfaceView`'s per-view and
    /// per-window observers) only fires for a view that is currently in a
    /// window, so this is also the only path that ever reaches a warm surface
    /// that missed the change entirely while detached.
    ///
    /// A session whose view has no window right now is skipped rather than
    /// refreshed: `GhosttySession`'s own scale lookup falls back to
    /// `NSScreen.main` with no window to read, which is only right by
    /// coincidence for a surface about to be mounted somewhere else. Such a
    /// session corrects itself on its own next mount instead (see
    /// `GhosttySurfaceView.viewDidMoveToWindow` -> `GhosttySession.attach`).
    func refreshContentScaleForLiveSessions() {
        for session in liveSessions() where session.view?.window != nil {
            session.updateContentScale()
        }
    }

    private func beginObservingApplicationFocus() {
        guard observers.isEmpty else { return }
        let notificationCenter = NotificationCenter.default
        observers.append(
            notificationCenter.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.setAppFocused(true)
                }
            }
        )
        observers.append(
            notificationCenter.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.setAppFocused(false)
                }
            }
        )
        observers.append(
            notificationCenter.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshContentScaleForLiveSessions()
                }
            }
        )
        setAppFocused(NSApp?.isActive == true)
    }

    private func setAppFocused(_ focused: Bool) {
        guard let app else { return }
        ghostty_app_set_focus(app, focused)
    }
}

private struct WeakGhosttySession {
    weak var value: GhosttySession?
}

// MARK: - libghostty callbacks
//
// These run on libghostty's threads, so they only unwrap the userdata pointer
// and hop to the main actor.

private let clipboardLog = Logger(subsystem: "dev.mattstack.flock", category: "clipboard")

private func ghosttyHostWakeup(_ userdata: UnsafeMutableRawPointer?) {
    guard let host = ghosttyHost(from: userdata) else { return }
    Task { @MainActor in
        host.tick()
    }
}

private func ghosttyHostAction(
    _ app: ghostty_app_t?,
    _ target: ghostty_target_s,
    _ action: ghostty_action_s
) -> Bool {
    guard let app, let host = ghosttyHost(from: ghostty_app_userdata(app)) else { return false }
    // The surface's session is resolved *here*, not inside the hop, and the
    // strong reference that produces is what keeps it alive until the action
    // is handled.
    //
    // Resolving it inside the `Task` instead is a use-after-free: libghostty
    // queues an action for a surface, the pane closes, `GhosttySession.deinit`
    // frees the surface, and the hop then runs `Unmanaged.takeUnretainedValue()`
    // on a session that is already gone. `EXC_BAD_ACCESS` at a small address,
    // intermittent, because it needs an action already in flight when the
    // surface goes away.
    let session = target.tag == GHOSTTY_TARGET_SURFACE
        ? ghosttySession(for: target.target.surface)
        : nil
    // Its strings are copied here for the same reason, and the reason is
    // worse: they are freed rather than merely unowned. See `actionText(from:)`.
    let text = actionText(from: action)
    Task { @MainActor in
        switch target.tag {
        case GHOSTTY_TARGET_SURFACE:
            session?.handle(action, text: text)
        case GHOSTTY_TARGET_APP:
            host.handle(action)
        default:
            host.tick()
        }
    }
    return true
}

/// libghostty's own paste road: the `paste_from_clipboard` binding (the
/// physical Paste key, and Cmd+V whenever AppKit's menu item did not take it
/// first) starts a clipboard request, and it arrives here.
///
/// Only a paste ever does. This callback is handed no request kind, so what
/// tells a paste from a program's OSC 52 read is that every surface is
/// configured `clipboard-read = deny` (`GhosttyThemeConfig.configText`) and
/// libghostty refuses the read before reaching here.
///
/// The text goes to the pane through the session, the same road the menu's
/// Paste takes, and the request is completed EMPTY so libghostty writes
/// nothing of its own: its text path strips the escape bytes that frame a
/// paste and splits what is left across three PTY writes (see
/// `PaneControlChannel.paste`). Completing rather than reporting the request
/// unstarted is what keeps the paste from ALSO landing as a literal Cmd+V --
/// that binding is `performable`, so a request libghostty is told never began
/// falls through to the key encoder.
private func ghosttyHostReadClipboard(
    _ userdata: UnsafeMutableRawPointer?,
    _ location: ghostty_clipboard_e,
    _ state: UnsafeMutableRawPointer?
) -> Bool {
    guard location != GHOSTTY_CLIPBOARD_SELECTION else { return false }
    guard let session = ghosttySession(from: userdata), let surface = session.surface else { return false }
    guard let text = NSPasteboard.general.pasteText() else { return false }
    "".withCString { ptr in
        ghostty_surface_complete_clipboard_request(surface, ptr, state, false)
    }
    // Resolved above, not inside the hop, for the same lifetime reason as
    // `ghosttyHostAction`.
    Task { @MainActor in
        session.paste(text)
    }
    return true
}

/// Where a clipboard request libghostty will not complete on its own lands.
/// Nothing routes here today: the read above completes a paste with an empty
/// string, which libghostty never judges unsafe, and `clipboard-read = deny`
/// refuses a program's OSC 52 read before a request exists to confirm.
///
/// EVERY path through here has to complete the request. It is a heap
/// allocation libghostty stops tracking the moment this callback is entered,
/// precisely so this route can own it, so returning without completing leaks
/// it and leaves the program that asked waiting for a reply that never comes.
private func ghosttyHostConfirmReadClipboard(
    _ userdata: UnsafeMutableRawPointer?,
    _ string: UnsafePointer<CChar>?,
    _ state: UnsafeMutableRawPointer?,
    _ request: ghostty_clipboard_request_e
) {
    let disposition = ClipboardReadDisposition.decide(request)
    guard let session = ghosttySession(from: userdata), let surface = session.surface else {
        clipboardLog.warning("clipboard request cannot be completed: its surface is already gone")
        return
    }
    let offered = string.map { String(cString: $0) } ?? ""
    // Completing on libghostty's own thread, re-entering the call that reached
    // this callback, is what the read above already does: the frame underneath
    // expects it and frees the request on the way back out.
    (disposition == .allow ? offered : "").withCString { pointer in
        ghostty_surface_complete_clipboard_request(surface, pointer, state, true)
    }
    if disposition == .deny {
        clipboardLog.notice(
            "denied a clipboard read for pane \(session.paneID.rawValue, privacy: .public) and completed it empty"
        )
    }
}

private func ghosttyHostWriteClipboard(
    _ userdata: UnsafeMutableRawPointer?,
    _ location: ghostty_clipboard_e,
    _ content: UnsafePointer<ghostty_clipboard_content_s>?,
    _ len: Int,
    _ confirm: Bool
) {
    guard location != GHOSTTY_CLIPBOARD_SELECTION else { return }
    guard let content, len > 0 else { return }
    let joined = UnsafeBufferPointer(start: content, count: len).compactMap { item -> String? in
        guard
            let mime = item.mime,
            String(cString: mime) == "text/plain",
            let value = item.data
        else { return nil }
        return String(cString: value)
    }.joined(separator: "\n")
    guard !joined.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(joined, forType: .string)
    // Resolved here, not inside the hop, for the same lifetime reason as
    // `ghosttyHostAction`: the strong reference keeps the session (and so
    // its host) alive until the main actor gets to it.
    guard let session = ghosttySession(from: userdata) else { return }
    Task { @MainActor in
        session.host.onClipboardWrite?(joined, session.paneID)
    }
}

private func ghosttyHostCloseSurface(_ userdata: UnsafeMutableRawPointer?, _ processAlive: Bool) {
    guard let session = ghosttySession(from: userdata) else { return }
    Task { @MainActor in
        session.handleCloseRequest(processAlive: processAlive)
    }
}

private func ghosttyHost(from pointer: UnsafeMutableRawPointer?) -> GhosttyHost? {
    guard let pointer else { return nil }
    return Unmanaged<GhosttyHost>.fromOpaque(pointer).takeUnretainedValue()
}

private func ghosttySession(for surface: ghostty_surface_t?) -> GhosttySession? {
    guard let surface, let userdata = ghostty_surface_userdata(surface) else { return nil }
    return ghosttySession(from: userdata)
}

private func ghosttySession(from pointer: UnsafeMutableRawPointer?) -> GhosttySession? {
    guard let pointer else { return nil }
    return Unmanaged<GhosttySession>.fromOpaque(pointer).takeUnretainedValue()
}

@MainActor
private extension GhosttyHost {
    /// App-targeted actions. Anything that would rearrange windows, tabs or
    /// splits is the shell's to decide, so it is deliberately not handled
    /// here. Config reload is also out of scope for this task: flock does
    /// not watch a config file, so there is nothing to reload yet.
    func handle(_ action: ghostty_action_s) {
        switch action.tag {
        case GHOSTTY_ACTION_RENDER:
            for session in liveSessions() {
                session.requestRender()
            }
        case GHOSTTY_ACTION_OPEN_CONFIG:
            openConfig()
        case GHOSTTY_ACTION_RING_BELL:
            NSSound.beep()
        default:
            break
        }
    }
}

/// Every string an action carries, copied while libghostty still owns it.
///
/// The pointers in a `ghostty_action_s` are libghostty's and do not outlive
/// the action callback, so reading one after the hop to the main actor is a
/// use-after-free -- and it does not crash, it lies: the memory has been
/// reused by then, so a hovered link can arrive as a run of the screen's
/// blank cells and an `open_url` as binary with a stale length. The struct
/// itself is a value and survives the hop on its own; only its strings need
/// copying here, so any new action carrying a pointer belongs in this
/// function too.
func actionText(from action: ghostty_action_s) -> String? {
    switch action.tag {
    case GHOSTTY_ACTION_SET_TITLE:
        return string(from: action.action.set_title.title)
    case GHOSTTY_ACTION_MOUSE_OVER_LINK:
        return string(
            from: action.action.mouse_over_link.url,
            length: Int(action.action.mouse_over_link.len)
        )
    case GHOSTTY_ACTION_OPEN_URL:
        return string(
            from: action.action.open_url.url,
            length: Int(action.action.open_url.len)
        )
    case GHOSTTY_ACTION_START_SEARCH:
        return string(from: action.action.start_search.needle)
    default:
        return nil
    }
}

private func string(from pointer: UnsafePointer<CChar>?) -> String? {
    guard let pointer else { return nil }
    return String(cString: pointer)
}

private func string(from pointer: UnsafePointer<CChar>?, length: Int) -> String? {
    guard let pointer, length > 0 else { return nil }
    let buffer = UnsafeBufferPointer(start: pointer, count: length)
    return String(decoding: buffer.map(UInt8.init(bitPattern:)), as: UTF8.self)
}
