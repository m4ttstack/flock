// Portions derived from Herdglass (BSL-1.1), Sources/Herdglass/Ghostty/TerminalSession.swift.
import AppKit
import Carbon
import GhosttyKit
import PaddockCore

/// One libghostty surface, and everything that has to be told about it: size,
/// scale, focus, occlusion, keys, mouse, clipboard and color scheme.
@MainActor
final class GhosttySession {
    /// What a surface should run and how it should be colored. `commandArgv`
    /// is the paddock bridge's own argv (`BridgeOptions.argv(...)`, this
    /// process's own path plus `--bridge <pane> --socket <path>`): the only
    /// child a paddock surface ever runs, since a surface with nothing to
    /// attach to is meaningless here. `themeColors` travels with the launch
    /// rather than being read from a global so a later per-pane theme
    /// override has somewhere to go; today every pane uses the same active
    /// `Theme`.
    struct Launch: Sendable {
        var commandArgv: [String]
        var themeColors: GhosttyThemeColors
        var workingDirectory: String?
        var fontSize: Float = 0
    }

    /// The parts of the terminal's state this app reads back.
    @MainActor
    final class State {
        fileprivate(set) var title: String?
        fileprivate(set) var hoveredLinkURL: String?
        fileprivate(set) var isMouseHidden = false
        /// The cell in pixels, which is how a wheel delta becomes a line count.
        fileprivate(set) var cellSize: (width: Int, height: Int)?
    }

    let host: GhosttyHost
    let state = State()
    private(set) var configuration: Launch
    /// Read from libghostty's own threads, which is why it is not actor isolated.
    nonisolated(unsafe) private(set) var surface: ghostty_surface_t?
    weak var view: GhosttySurfaceView?
    /// The surface's process went away. `processAlive` is true when libghostty
    /// is asking to close rather than reporting a child that already exited.
    var closeHandler: ((Bool) -> Void)?
    nonisolated(unsafe) private var secureEventInputEnabled = false

    init(host: GhosttyHost, configuration: Launch) {
        self.host = host
        self.configuration = configuration
        host.register(self)
    }

    deinit {
        if secureEventInputEnabled {
            DisableSecureEventInput()
        }
        if let surface {
            ghostty_surface_free(surface)
        }
    }

    /// Creates the surface the first time, then re-syncs everything that
    /// depends on where the view ended up. Called again after the view is
    /// laid out, which is why it has to be idempotent -- and why a nil
    /// surface (no window/screen yet for libghostty's `CVDisplayLink`, or a
    /// locked screen) is not fatal: the next `attach` (the next
    /// `viewDidMoveToWindow`, or the layout pass right after) tries again.
    /// Until then the view just shows its theme's background color, which is
    /// this session's placeholder.
    func attach(to view: GhosttySurfaceView) {
        self.view = view
        if surface == nil {
            createSurface(in: view)
        }
        updateContentScale()
        resize(to: view.bounds.size)
        setDisplayID(displayID(of: view))
        setFocused(view.window?.firstResponder === view)
        applyColorScheme(appearance: view.effectiveAppearance)
    }

    /// `ghostty_surface_config_s` has no size field: a new surface is always
    /// born at libghostty's own internal placeholder size, so every attach
    /// (first or not) resizes to the view's real bounds unconditionally.
    func resize(to size: CGSize) {
        guard let surface else { return }
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
        ghostty_surface_set_size(surface, UInt32(ceil(size.width * scale)), UInt32(ceil(size.height * scale)))
        ghostty_surface_refresh(surface)
    }

    func updateContentScale() {
        guard let surface else { return }
        let scale = Double(scale)
        guard scale.isFinite, scale > 0 else { return }
        ghostty_surface_set_content_scale(surface, scale, scale)
    }

    func render() {
        guard let surface else { return }
        ghostty_surface_draw(surface)
    }

    /// Renders through the view when there is one, so a burst of requests
    /// collapses into one draw per pass.
    func requestRender() {
        if let view {
            view.requestRender()
        } else {
            render()
        }
    }

    func setFocused(_ focused: Bool) {
        guard let surface else { return }
        ghostty_surface_set_focus(surface, focused)
    }

    func setOccluded(_ occluded: Bool) {
        guard let surface else { return }
        ghostty_surface_set_occlusion(surface, !occluded)
    }

    func setDisplayID(_ displayID: CGDirectDisplayID?) {
        guard let surface, let displayID else { return }
        ghostty_surface_set_display_id(surface, displayID)
    }

    func keyboardLayoutChanged() {
        guard let app = host.app else { return }
        ghostty_app_keyboard_changed(app)
    }

    func sendKeyDown(_ event: NSEvent, text: String?) {
        sendKeyEvent(event, action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS, text: text)
        ghostty_surface_refresh(surface)
    }

    func sendKeyUp(_ event: NSEvent) {
        sendKeyEvent(event, action: GHOSTTY_ACTION_RELEASE, text: nil)
        ghostty_surface_refresh(surface)
    }

    func insertText(_ text: String) {
        guard let surface, !text.isEmpty else { return }
        text.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(text.utf8.count))
        }
        ghostty_surface_refresh(surface)
    }

    /// The in-progress text of an input method. `nil` clears it.
    func setMarkedText(_ text: String?) {
        guard let surface else { return }
        guard let text else {
            ghostty_surface_preedit(surface, nil, 0)
            ghostty_surface_refresh(surface)
            return
        }
        text.withCString { ptr in
            ghostty_surface_preedit(surface, ptr, UInt(text.utf8.count))
        }
        ghostty_surface_refresh(surface)
    }

    /// True when libghostty consumed the click, i.e. the program in the pane
    /// wanted it. A false means the view can offer its own context menu.
    @discardableResult
    func sendMouseButton(_ button: GhosttySurfaceView.MouseButton, pressed: Bool, event: NSEvent) -> Bool {
        guard let surface else { return false }
        let state: ghostty_input_mouse_state_e = pressed ? GHOSTTY_MOUSE_PRESS : GHOSTTY_MOUSE_RELEASE
        return ghostty_surface_mouse_button(surface, state, translate(button), translate(event.modifierFlags))
    }

    func sendMousePosition(_ event: NSEvent) {
        guard let surface, let view else { return }
        let position = view.convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(
            surface,
            position.x,
            view.bounds.height - position.y,
            translate(event.modifierFlags)
        )
    }

    func sendMouseExit(modifiers: NSEvent.ModifierFlags) {
        guard let surface else { return }
        ghostty_surface_mouse_pos(surface, -1, -1, translate(modifiers))
    }

    /// The wheel stays entirely local to libghostty's own scrollback: unlike
    /// keystrokes, a scroll gesture never becomes a `terminal.scroll` message
    /// on the bridge's control channel (herdr's pane scrollback is real,
    /// shared viewport state -- see `ControlBridge.parseForwardableControlCommand`
    /// and `PaneControlChannel`'s doc comment), so there is no diversion hook
    /// here the way Herdglass's `onScrollWheel` had one.
    func sendScrollWheel(_ event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_scroll(surface, event.scrollingDeltaX, event.scrollingDeltaY, translateScrollModifiers(event))
    }

    /// Copies the selection with libghostty's own action rather than reading
    /// the cells back ourselves: only the action honours
    /// `clipboard-trim-trailing-spaces`, so only the action leaves behind the
    /// blank cells padding each row out to the pane's width. It writes the
    /// clipboard through `GhosttyHost`'s write-clipboard callback.
    @discardableResult
    func copySelection() -> Bool {
        perform(action: "copy_to_clipboard:plain")
    }

    func hasSelection() -> Bool {
        guard let surface else { return false }
        return ghostty_surface_has_selection(surface)
    }

    func paste(_ text: String) {
        insertText(text)
    }

    func openHoveredLink() {
        guard let url = state.hoveredLinkURL, let value = URL(string: url) else { return }
        NSWorkspace.shared.open(value)
    }

    /// Runs one of libghostty's own keybind actions by name, e.g. `select_all`.
    @discardableResult
    func perform(action: String) -> Bool {
        guard let surface else { return false }
        return action.withCString { ptr in
            ghostty_surface_binding_action(surface, ptr, UInt(action.utf8.count))
        }
    }

    func applyColorScheme(appearance: NSAppearance? = nil) {
        guard let surface, let scheme = colorScheme(for: appearance ?? view?.effectiveAppearance) else { return }
        ghostty_surface_set_color_scheme(surface, scheme)
        ghostty_surface_refresh(surface)
    }

    /// Restyles a LIVE surface: unlike `createSurface`'s one-time app-config
    /// swap, this pushes straight onto the surface that already exists via
    /// `ghostty_surface_update_config` (ghostty's own live-reload entry
    /// point -- see `Surface.zig`'s `updateConfig`, which only touches
    /// rendering-affecting state and never re-runs the surface's command),
    /// so a theme change repaints every focused pane without tearing its
    /// bridge down. Ported from Herdglass's `TerminalSession.updateConfig`
    /// (BSL-1.1, attributed): push, then re-apply the light/dark scheme the
    /// same way `attach` does, since a config push does not imply one.
    @discardableResult
    func updateTheme(_ colors: GhosttyThemeColors) -> Bool {
        configuration.themeColors = colors
        guard let surface else { return false }
        guard host.updateLiveConfig(surface: surface, colors: colors, commandArgv: configuration.commandArgv) else {
            return false
        }
        applyColorScheme(appearance: view?.effectiveAppearance)
        requestRender()
        return true
    }

    /// The two AppKit text commands libghostty has bindings for. Everything
    /// else the view suppresses or passes on.
    func performCommand(_ selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveToBeginningOfDocument(_:)):
            return perform(action: "scroll_to_top")
        case #selector(NSResponder.moveToEndOfDocument(_:)):
            return perform(action: "scroll_to_bottom")
        default:
            return false
        }
    }

    func handleCloseRequest(processAlive: Bool) {
        closeHandler?(processAlive)
    }

    /// Surface-targeted actions. The window/tab/split ones are the shell's to
    /// decide -- this app draws what the server reports -- so they are
    /// dropped rather than handled.
    func handle(_ action: ghostty_action_s, text: String?) {
        switch action.tag {
        case GHOSTTY_ACTION_RENDER:
            requestRender()
        case GHOSTTY_ACTION_SET_TITLE:
            state.title = text
        case GHOSTTY_ACTION_MOUSE_OVER_LINK:
            state.hoveredLinkURL = text
        case GHOSTTY_ACTION_OPEN_URL:
            if let text, let value = URL(string: text) {
                NSWorkspace.shared.open(value)
            }
        case GHOSTTY_ACTION_MOUSE_SHAPE:
            view?.applyCursor(for: action.action.mouse_shape)
        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            let hidden = action.action.mouse_visibility == GHOSTTY_MOUSE_HIDDEN
            state.isMouseHidden = hidden
            view?.setCursorHidden(hidden)
        case GHOSTTY_ACTION_CELL_SIZE:
            state.cellSize = (
                width: Int(action.action.cell_size.width),
                height: Int(action.action.cell_size.height)
            )
        case GHOSTTY_ACTION_COPY_TITLE_TO_CLIPBOARD:
            let title = state.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let title, !title.isEmpty {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(title, forType: .string)
            }
        case GHOSTTY_ACTION_RING_BELL:
            NSSound.beep()
        case GHOSTTY_ACTION_OPEN_CONFIG:
            host.openConfig()
        case GHOSTTY_ACTION_SECURE_INPUT:
            // A password prompt in the pane asks for this, and it is the only
            // way to stop other processes seeing the keystrokes.
            switch action.action.secure_input {
            case GHOSTTY_SECURE_INPUT_ON:
                guard !secureEventInputEnabled else { break }
                EnableSecureEventInput()
                secureEventInputEnabled = true
            case GHOSTTY_SECURE_INPUT_OFF:
                guard secureEventInputEnabled else { break }
                DisableSecureEventInput()
                secureEventInputEnabled = false
            default:
                break
            }
        default:
            break
        }
    }

    /// The scale to report to libghostty. The window's own is the truthful
    /// one; the fallbacks only matter while the view is between windows.
    private var scale: CGFloat {
        view?.window?.backingScaleFactor
            ?? view?.window?.screen?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
    }

    /// `ghostty_surface_new` returns null rather than throwing: libghostty
    /// builds a `CVDisplayLink` from the view's screen, so a view that is not
    /// on one yet (a locked screen counts) cannot have a surface. Callers
    /// check `surface`; `attach` retries on the next call.
    private func createSurface(in view: NSView) {
        guard let app = host.app else { return }
        // The one command a paddock surface's child ever needs travels
        // through the app-config workaround, not through this struct's
        // `command` field below (see `GhosttyHost.configureNextSurface`'s
        // doc comment for why the field alone does nothing). This has to run
        // before `ghostty_surface_new`, not after: the surface reads the
        // app's config once, at creation.
        guard host.configureNextSurface(colors: configuration.themeColors, commandArgv: configuration.commandArgv) else { return }

        if let scheme = colorScheme(for: view.effectiveAppearance) {
            ghostty_app_set_color_scheme(app, scheme)
        }

        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(view).toOpaque()))
        config.userdata = Unmanaged.passUnretained(self).toOpaque()
        config.scale_factor = Double(scale)
        config.font_size = configuration.fontSize
        config.context = GHOSTTY_SURFACE_CONTEXT_WINDOW

        configuration.workingDirectory.withOptionalCString { workingDirectory in
            config.working_directory = workingDirectory
            configuration.commandArgv.joined(separator: " ").withCString { command in
                config.command = command
                surface = ghostty_surface_new(app, &config)
            }
        }

        if let surface, let scheme = colorScheme(for: view.effectiveAppearance) {
            ghostty_surface_set_color_scheme(surface, scheme)
        }
    }

    private func sendKeyEvent(_ event: NSEvent, action: ghostty_input_action_e, text: String?) {
        guard let surface else { return }
        var key = ghostty_input_key_s()
        key.action = action
        key.keycode = UInt32(event.keyCode)
        key.mods = translate(event.modifierFlags)
        key.consumed_mods = ghostty_surface_key_translation_mods(surface, key.mods)
        key.composing = false
        key.unshifted_codepoint = event.charactersIgnoringModifiers?.unicodeScalars.first?.value ?? 0

        if let text, !text.isEmpty {
            text.withCString { ptr in
                key.text = ptr
                _ = ghostty_surface_key(surface, key)
            }
        } else {
            key.text = nil
            _ = ghostty_surface_key(surface, key)
        }
    }

    private func displayID(of view: NSView) -> CGDirectDisplayID? {
        guard let screenNumber = view.window?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(screenNumber.uint32Value)
    }

    private func colorScheme(for appearance: NSAppearance?) -> ghostty_color_scheme_e? {
        let match = (appearance ?? NSApp?.effectiveAppearance ?? NSAppearance(named: .aqua))?
            .bestMatch(from: [.darkAqua, .aqua])
        return match == .darkAqua ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
    }

    private func translate(_ button: GhosttySurfaceView.MouseButton) -> ghostty_input_mouse_button_e {
        switch button {
        case .left: return GHOSTTY_MOUSE_LEFT
        case .right: return GHOSTTY_MOUSE_RIGHT
        case .other(let number):
            switch number {
            case 2: return GHOSTTY_MOUSE_MIDDLE
            case 3: return GHOSTTY_MOUSE_FOUR
            case 4: return GHOSTTY_MOUSE_FIVE
            case 5: return GHOSTTY_MOUSE_SIX
            case 6: return GHOSTTY_MOUSE_SEVEN
            case 7: return GHOSTTY_MOUSE_EIGHT
            case 8: return GHOSTTY_MOUSE_NINE
            case 9: return GHOSTTY_MOUSE_TEN
            case 10: return GHOSTTY_MOUSE_ELEVEN
            default: return GHOSTTY_MOUSE_UNKNOWN
            }
        }
    }

    /// AppKit's flags mapped into `GhosttyKeyModifiers`, then through
    /// `GhosttyKeyMods.translate` (pure, unit-tested in `PaddockCoreTests`)
    /// for the actual bit table.
    private func translate(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods = GhosttyKeyModifiers()
        if flags.contains(.shift) { mods.insert(.shift) }
        if flags.contains(.control) { mods.insert(.control) }
        if flags.contains(.option) { mods.insert(.option) }
        if flags.contains(.command) { mods.insert(.command) }
        if flags.contains(.capsLock) { mods.insert(.capsLock) }
        return GhosttyKeyMods.translate(mods)
    }

    /// Scroll modifiers carry the momentum phase in the high bits, which is
    /// how libghostty tells a flick from a drag.
    private func translateScrollModifiers(_ event: NSEvent) -> ghostty_input_scroll_mods_t {
        var value = ghostty_input_scroll_mods_t(translate(event.modifierFlags).rawValue)
        switch event.momentumPhase {
        case .began:
            value |= ghostty_input_scroll_mods_t(GHOSTTY_MOUSE_MOMENTUM_BEGAN.rawValue << 16)
        case .changed:
            value |= ghostty_input_scroll_mods_t(GHOSTTY_MOUSE_MOMENTUM_CHANGED.rawValue << 16)
        case .ended:
            value |= ghostty_input_scroll_mods_t(GHOSTTY_MOUSE_MOMENTUM_ENDED.rawValue << 16)
        case .cancelled:
            value |= ghostty_input_scroll_mods_t(GHOSTTY_MOUSE_MOMENTUM_CANCELLED.rawValue << 16)
        case .mayBegin:
            value |= ghostty_input_scroll_mods_t(GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN.rawValue << 16)
        default:
            break
        }
        if event.hasPreciseScrollingDeltas {
            value |= 1 << 24
        }
        return value
    }
}

private extension Optional where Wrapped == String {
    func withOptionalCString<T>(_ body: (UnsafePointer<CChar>?) -> T) -> T {
        switch self {
        case .none:
            return body(nil)
        case .some(let value):
            return value.withCString(body)
        }
    }
}
