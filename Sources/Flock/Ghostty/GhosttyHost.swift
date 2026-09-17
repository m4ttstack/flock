// Portions derived from Herdglass (BSL-1.1), Sources/Herdglass/Ghostty/TerminalHost.swift
// and Sources/Herdglass/GhosttyRuntime.swift (the config-loading half only;
// the window-chrome config reader in GhosttyConfig.swift is not ported here).
import AppKit
import GhosttyKit
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
    /// whose surface wrote it, by any surface (copy-on-select's mouse-up, an
    /// explicit copy action), after the pasteboard write has happened, on
    /// the main actor.
    var onClipboardWrite: ((String, PaneID) -> Void)?

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
        colors: GhosttyThemeColors, commandArgv: [String], fontFamily: String, fontSizePoints: Double
    ) -> Bool {
        guard let app, let baseConfig, !commandArgv.isEmpty else { return false }
        let text = GhosttyThemeConfig.configText(
            colors: colors, commandArgv: commandArgv, fontFamily: fontFamily, fontSizePoints: fontSizePoints
        )
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("flock-surface-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString.prefix(8)).ghostty")
        guard (try? text.write(to: file, atomically: true, encoding: .utf8)) != nil,
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
        return true
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
        fontFamily: String, fontSizePoints: Double
    ) -> Bool {
        guard let baseConfig, !commandArgv.isEmpty else { return false }
        let text = GhosttyThemeConfig.configText(
            colors: colors, commandArgv: commandArgv, fontFamily: fontFamily, fontSizePoints: fontSizePoints
        )
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("flock-surface-update-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString.prefix(8)).ghostty")
        guard (try? text.write(to: file, atomically: true, encoding: .utf8)) != nil,
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

private func ghosttyHostReadClipboard(
    _ userdata: UnsafeMutableRawPointer?,
    _ location: ghostty_clipboard_e,
    _ state: UnsafeMutableRawPointer?
) -> Bool {
    guard location != GHOSTTY_CLIPBOARD_SELECTION else { return false }
    guard let session = ghosttySession(from: userdata), let surface = session.surface else { return false }
    guard let text = NSPasteboard.general.string(forType: .string) else { return false }
    text.withCString { ptr in
        ghostty_surface_complete_clipboard_request(surface, ptr, state, false)
    }
    return true
}

/// libghostty asks before pasting something that looks unsafe. This app
/// pastes what the user asked for and never prompts, which is also what the
/// read above does by passing `confirmed: false`.
private func ghosttyHostConfirmReadClipboard(
    _ userdata: UnsafeMutableRawPointer?,
    _ string: UnsafePointer<CChar>?,
    _ state: UnsafeMutableRawPointer?,
    _ request: ghostty_clipboard_request_e
) {
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
