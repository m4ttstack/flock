// Portions derived from Herdglass (BSL-1.1), Sources/Herdglass/Ghostty/TerminalSession.swift.
import AppKit
import Carbon
import GhosttyKit
import os
import FlockCore

/// One libghostty surface, and everything that has to be told about it: size,
/// scale, focus, occlusion, keys, mouse, clipboard and color scheme.
@MainActor
final class GhosttySession {
    /// What a surface should run and how it should be colored. `commandArgv`
    /// is the flock bridge's own argv (`BridgeOptions.argv(...)`, this
    /// process's own path plus `--bridge <pane> --socket <path>`): the only
    /// child a flock surface ever runs, since a surface with nothing to
    /// attach to is meaningless here. `themeColors` travels with the launch
    /// rather than being read from a global so a later per-pane theme
    /// override has somewhere to go; today every pane uses the same active
    /// `Theme`.
    struct Launch: Sendable {
        var commandArgv: [String]
        var themeColors: GhosttyThemeColors
        var workingDirectory: String?
        /// The Terminal Text size (points) at creation time; travels with
        /// the launch the same way `themeColors` does. A later change flows
        /// through `updateAppearance`, not back through this struct.
        var fontSizePoints: Double = Double(TerminalTextSize.regular.points)
        /// Whether Option acts as Alt at creation time, same travel rule as
        /// `fontSizePoints`.
        var optionAsAlt: OptionAsAlt = .left
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
    /// This surface's pane, the way `write_clipboard_cb` identifies which
    /// pane's whisper toast to show: resolved once here at construction,
    /// never re-derived from the surface pointer at callback time.
    let paneID: PaneID
    let state = State()
    let search = TerminalSearch()
    private(set) var configuration: Launch
    /// Read from libghostty's own threads, which is why it is not actor isolated.
    nonisolated(unsafe) private(set) var surface: ghostty_surface_t?
    /// The view currently hosting this session's surface, or `nil` before
    /// the first attach. Strong, not weak: a parked pane's cell disappears
    /// from SwiftUI's own hierarchy (its tab is no longer selected), and
    /// only this reference then keeps the view -- and, through it, the live
    /// libghostty surface -- alive across that, so a later re-host
    /// (`GhosttySurfaceRepresentable.makeNSView` returning it again) shows
    /// the pane's CURRENT content instead of a freshly recreated surface.
    /// This creates a retain cycle with `GhosttySurfaceView.session` (also
    /// strong) by design; `GhosttySessionSurfaceHandle.detach()` is what
    /// breaks it, by nilling this out, on the only two paths that ever
    /// really end a pane's surface for good (the warm cap's eviction, and a
    /// pane herdr no longer reports).
    var view: GhosttySurfaceView?
    /// Latches true the first time the bridge reports (over the status
    /// FIFO) that it wrote a full-redraw frame to the PTY. A separate
    /// `@Observable` box, not a plain stored property, so `PaneCellView` can
    /// track it through the type-erased `GhosttyPaneSurface` existential --
    /// see `FirstFrameLatch`'s own doc comment.
    let firstFrameLatch = FirstFrameLatch()
    var hasFirstFrame: Bool { firstFrameLatch.received }
    /// The surface's process went away. `processAlive` is true when libghostty
    /// is asking to close rather than reporting a child that already exited.
    var closeHandler: ((Bool) -> Void)?
    /// Fired by `GhosttySurfaceView.keyDown` for real user key input (never
    /// from `flagsChanged`, and never for a bare Command combo -- see that
    /// call site). Set by `GhosttyControlSurfaceFactory.makeSurface` at
    /// creation, from `SessionViewModel`'s own `recordLauncherKeystroke`:
    /// without this, a real keystroke into a pristine pane would never hide
    /// the launcher overlay, leaving it hit-testable over live terminal
    /// output.
    var onUserInput: (() -> Void)?
    /// Fired by `GhosttySurfaceView.keyDown` for the key that asks a pane to
    /// clear its screen, AFTER `onUserInput` for the same event: clearing is
    /// still typing, so the keystroke has to land first and the clear is what
    /// reopens the question the keystroke just closed.
    var onClearRequested: (() -> Void)?
    /// The chosen scroll speed, asked for at wheel time rather than carried
    /// in `configuration` the way the font size is: a speed picked from the
    /// View menu has to reach the panes that already exist, and nothing is
    /// drawn from it, so there is no appearance for a snapshot to keep in
    /// step. Set by `GhosttyControlSurfaceFactory.makeSurface` at creation.
    var scrollSpeed: () -> ScrollSpeed = { .normal }
    nonisolated(unsafe) private var secureEventInputEnabled = false
    /// The FIFO to this pane's bridge, set by `GhosttyControlSurfaceFactory`
    /// right after construction (before the session is ever attached to a
    /// view). Retained for the session's whole life: releasing it (session
    /// `deinit`) closes and unlinks the FIFO the same way freeing the
    /// libghostty surface ends the bridge's PTY.
    var controlChannel: PaneControlChannel?
    /// The FIFO the bridge reports pane state on (`flock.mouse_capture`),
    /// set by `GhosttyControlSurfaceFactory` alongside `controlChannel` and
    /// retained for the session's whole life: releasing it (session `deinit`)
    /// closes and unlinks the FIFO the same way freeing the surface ends the
    /// PTY. Its reader callback drives `mouseCaptureEnabled`.
    var statusChannel: PaneStatusChannel?

    /// Whether the pane's own program has asked for mouse reporting, as last
    /// reported by the bridge over `statusChannel`. Flock's libghostty never
    /// enters reporting mode itself (its screen is a repaint of herdr's, not
    /// the raw DECSET), so this out-of-band flag is what tells the view
    /// whether a click belongs to the app (`.toApp` via the control FIFO) or
    /// to libghostty's own selection. `sgr_pixels` is not kept: a control
    /// client never negotiates pixel mouse, so herdr always reports it false.
    private(set) var mouseCaptureEnabled = false
    /// Latched by the first `setMouseCapture(enabled: true)`: see `MouseClaimLatch`.
    let mouseClaimLatch = MouseClaimLatch()
    var hasClaimedMouse: Bool { mouseClaimLatch.claimed }

    /// The grid flock's pane box holds, which the view lays the surface out
    /// at. Kept only so `verifyExpectedGrid` can log whether libghostty's live
    /// grid matches it.
    private var expectedGrid: (cols: Int, rows: Int)?
    private var lastVerifiedGrid: (cols: Int, rows: Int)?

    init(host: GhosttyHost, paneID: PaneID, configuration: Launch) {
        self.host = host
        self.paneID = paneID
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
    /// (first or not) resizes to the view's real bounds unconditionally. The
    /// bounds are `PaneCellView`'s exact cols x rows cells. libghostty resizes
    /// the PTY only once it applies the grid, and the bridge's SIGWINCH is what
    /// tells herdr, so nothing here may send a size of its own.
    func resize(to size: CGSize) {
        guard let surface else { return }
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
        ghostty_surface_set_size(surface, UInt32(ceil(size.width * scale)), UInt32(ceil(size.height * scale)))
        ghostty_surface_refresh(surface)
        verifyExpectedGrid()
    }

    /// Records the grid flock's box holds for this pane, for the grid log.
    /// It is not checked here: a new box grid arrives before AppKit lays the
    /// new frame out, so libghostty still holds the old grid. `resize(to:)`
    /// and `updateAppearance` check it once the grid can have moved.
    func setExpectedGrid(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        if let expectedGrid, expectedGrid.cols == cols, expectedGrid.rows == rows { return }
        expectedGrid = (cols, rows)
        lastVerifiedGrid = nil
    }

    /// Runs whenever libghostty's live grid may have changed. On a real change
    /// it tells the bridge to relay the PTY's new size, and logs, once per
    /// (expected, actual) change, whether the grid equals the box grid. A
    /// mismatch after the font has settled means `TerminalCellMetrics`
    /// disagrees with the cell libghostty actually loaded, and herdr then runs
    /// at libghostty's grid rather than the box's.
    ///
    /// The nudge is the only way a box change reaches the pane's real grid
    /// while flock holds the pane: herdr skips every terminal in
    /// `direct_attach_resize_locks` when it resizes a tab's panes, the zoom
    /// branch included, so a pane blown up to the whole canvas by a zoom would
    /// otherwise keep rendering its old grid until the next hold re-take.
    private func verifyExpectedGrid() {
        guard let expectedGrid, let geometry = surfaceGeometry() else { return }
        let actual = (geometry.grid.columns, geometry.grid.rows)
        if let lastVerifiedGrid, lastVerifiedGrid == actual { return }
        lastVerifiedGrid = actual
        controlChannel?.syncSize()
        let matches = actual == expectedGrid
        Self.gridLog.log(
            level: matches ? .default : .error,
            "surface grid pane=\(self.paneID.rawValue, privacy: .public) cols=\(actual.0) rows=\(actual.1) expected=\(expectedGrid.cols)x\(expectedGrid.rows) cell=\(geometry.cellPixels.width)x\(geometry.cellPixels.height)px font=\(self.configuration.fontSizePoints) match=\(matches)"
        )
    }

    private static let gridLog = Logger(subsystem: "dev.mattstack.flock", category: "grid")

    /// The scale most recently written to the surface, so a call that finds
    /// nothing changed (every `layout()` pass reasserts it) is a no-op rather
    /// than a redundant `ghostty_surface_set_content_scale`.
    private var lastAppliedScale: CGFloat?
    /// Real writes to libghostty's content scale, counted (not just logged)
    /// so a test can prove a repeated call with nothing changed issues none.
    private(set) var contentScaleApplyCount = 0

    /// A display notification can arrive before the window's backing scale
    /// actually updates, so the event-driven callers alone can leave this
    /// stale until the app restarts; `GhosttySurfaceView.layout()` calling
    /// this on every pass is what corrects a miss regardless of ordering.
    /// Requiring a window here is what keeps that self-heal from writing
    /// `scale`'s `NSScreen.main` fallback into a session whose view is
    /// parked in the warm cache awaiting mount elsewhere.
    func updateContentScale() {
        guard let surface, let view, view.window != nil else { return }
        let newScale = scale
        guard newScale.isFinite, newScale > 0 else { return }
        // libghostty's renderer makes the view layer-HOSTING and stamps its
        // layer's `contentsScale` once, at creation. AppKit never updates a
        // hosted layer, and the renderer sizes every frame from it, so a
        // stale one draws the old scale's frame into a corner of the pane.
        if let layer = view.layer, layer.contentsScale != newScale {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.contentsScale = newScale
            CATransaction.commit()
        }
        guard newScale != lastAppliedScale else { return }
        lastAppliedScale = newScale
        contentScaleApplyCount += 1
        let value = Double(newScale)
        ghostty_surface_set_content_scale(surface, value, value)
        // The surface's size is in PIXELS and `resize` derives it from this
        // scale, so the size the surface still holds now names the wrong
        // number of pixels and its grid moves by the scale ratio: twice the
        // columns dropping to 1x, half of them going back up. Nothing else
        // re-issues it, because AppKit runs no layout pass when a window
        // moves between displays of the same point size, and that is exactly
        // the move plugging a monitor in makes.
        resize(to: view.bounds.size)
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
        guard let surface else { return }
        sendKeyEvent(event, action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS, text: text)
        ghostty_surface_refresh(surface)
    }

    func sendKeyUp(_ event: NSEvent) {
        guard let surface else { return }
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
    /// `modifierOverride`, when given, replaces `event.modifierFlags` for
    /// the mods ghostty sees -- an Option-held right click forwarded via
    /// `RightClickDisposition.forwardToPane` strips `.option` first so the
    /// pane sees a plain right click, not alt+right (see
    /// `GhosttySurfaceView.rightMouseDown`).
    @discardableResult
    func sendMouseButton(
        _ button: GhosttySurfaceView.MouseButton, pressed: Bool, event: NSEvent,
        modifierOverride: NSEvent.ModifierFlags? = nil
    ) -> Bool {
        guard let surface else { return false }
        let state: ghostty_input_mouse_state_e = pressed ? GHOSTTY_MOUSE_PRESS : GHOSTTY_MOUSE_RELEASE
        return ghostty_surface_mouse_button(surface, state, translate(button), translate(modifierOverride ?? event.modifierFlags))
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

    /// The launcher-pristine contract's screen-activity half: called with
    /// this pane's current non-empty retained-row count on every real
    /// content change (see `reportScreenActivityIfDue`'s own doc), so a
    /// pane whose program prints real output -- never typed into -- also
    /// hides the overlay. Returns whether to keep reporting; `false` (no
    /// longer pristine) makes this session stop calling it for good.
    var onScreenActivity: ((Int) -> Bool)?
    private var screenActivityStillWanted = true
    private var lastScreenActivityCheck = Date.distantPast

    /// Turns row counting back on after it has been switched off. A clear key
    /// is the only caller: the question it reopens ("is this pane empty
    /// again?") can only be answered by counting, and the answer has to be
    /// read from the screen the shell paints a moment later, not from the key
    /// itself. `lastScreenActivityCheck` is reset too, so the very next render
    /// reports rather than waiting out a throttle interval that began while
    /// the pane was still busy.
    func resumeScreenActivityReporting() {
        screenActivityStillWanted = true
        lastScreenActivityCheck = .distantPast
    }

    /// Throttled to at most 4 times a second, and only while some listener
    /// still wants to know: `GHOSTTY_ACTION_RENDER` is ghostty's own "real
    /// content changed, please redraw" signal (see `handle`'s own case for
    /// it), which is what makes this an actual content-change hook rather
    /// than a blind timer -- counting non-empty rows walks the whole active
    /// screen (`readScreenRows`'s underlying `ghostty_surface_read_text` call
    /// is documented "expensive" by libghostty itself), so it must never run
    /// once per render.
    private func reportScreenActivityIfDue() {
        guard screenActivityStillWanted, let onScreenActivity else { return }
        let now = Date()
        guard now.timeIntervalSince(lastScreenActivityCheck) >= 0.25 else { return }
        lastScreenActivityCheck = now
        let nonEmptyRows = readScreenRows().reduce(into: 0) { count, line in
            if !line.trimmingCharacters(in: .whitespaces).isEmpty { count += 1 }
        }
        screenActivityStillWanted = onScreenActivity(nonEmptyRows)
    }

    /// The ACTIVE area -- the editable screen a running program can address --
    /// not `GHOSTTY_POINT_SCREEN`, which ghostty defines as reaching "the
    /// furthest back in the scrollback history" (`terminal/point.zig`).
    ///
    /// That distinction is the whole feature. Clearing a pane empties the
    /// screen and keeps the scrollback, so a scrollback-wide count barely
    /// moves and never returns to what the pane settled at: the clear can
    /// never be detected, which is exactly how it shipped. It also makes the
    /// scan cost grow with the session's history rather than staying the size
    /// of the window.
    private func readScreenRows() -> [String] {
        guard let surface else { return [] }
        var text = ghostty_text_s()
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_ACTIVE, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(
                tag: GHOSTTY_POINT_ACTIVE, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false)
        guard ghostty_surface_read_text(surface, selection, &text) else { return [] }
        defer { ghostty_surface_free_text(surface, &text) }
        guard text.text_len > 0 else { return [] }
        return String(cString: text.text).components(separatedBy: "\n")
    }

    /// Every paste road ends here, and every paste leaves on the pane's control
    /// channel rather than through the surface: the terminal whose mode decides
    /// what a paste means is herdr's, not this one, and only a complete
    /// bracketed paste tells it a paste from typed input
    /// (`PaneControlChannel.paste`).
    ///
    /// `insertText` remains for a pane whose control FIFO could not be made
    /// (`GhosttyControlSurfaceFactory` logs that). It reaches the program
    /// unframed, which is what every paste did before, and is the only thing
    /// left that reaches it at all.
    func paste(_ text: String) {
        guard let controlChannel else {
            insertText(text)
            return
        }
        controlChannel.paste(text)
    }

    /// Records the pane app's mouse-reporting state as reported by the bridge
    /// (called on the main actor from `statusChannel`'s reader). A true ->
    /// false transition tells the view to drop any pending wheel remainder:
    /// a momentum tail that lands after the app disabled mouse mode would
    /// otherwise still be forwarded, and herdr routes a wheel event on a
    /// non-reporting pane to its SHARED scrollback viewport.
    func setMouseCapture(enabled: Bool) {
        let wasEnabled = mouseCaptureEnabled
        mouseCaptureEnabled = enabled
        if enabled {
            mouseClaimLatch.markClaimed()
        }
        if wasEnabled, !enabled {
            view?.mouseCaptureDidEnd()
        }
    }

    /// Called once, from `statusChannel`'s reader, when the bridge reports
    /// its first full-redraw frame. Idempotent past the first call --
    /// `FirstFrameLatch.markReceived()` never flips back -- since herdr sends
    /// a fresh full frame after every resize, and that must never re-show a
    /// pane's status card.
    func markFirstFrameReceived() {
        firstFrameLatch.markReceived()
    }

    /// Called from `statusChannel`'s reader when the bridge gives up retaking
    /// its herdr hold. The pane's status card comes back, because the frame on
    /// screen is no longer live and nothing further is pending.
    func markHoldLost() {
        firstFrameLatch.markHoldLost()
    }

    /// Sends one structured mouse event to the pane's own program over the
    /// control FIFO. The only path to the app's mouse handling, since
    /// flock's libghostty is never in reporting mode.
    func sendPaneMouse(_ command: MouseForwarding.Command) {
        controlChannel?.send(command.json())
    }

    /// Moves the pane's real, shared herdr viewport: the wheel's destination
    /// whenever the app has not claimed the mouse (see
    /// `MouseForwarding.Decision.toHerdrScroll`). Only ever called for the
    /// resolved-focused pane -- an unfocused pane's wheel is dropped upstream
    /// in `MouseForwarding.decide`, before this could be reached.
    func sendPaneScroll(direction: PaneControlChannel.ScrollDirection, lines: Int) {
        controlChannel?.scroll(direction: direction, lines: lines)
    }

    /// Tells the bridge to drop, or retake, its herdr control client. Nothing
    /// on this side is torn down or rebuilt: the surface, its PTY and its
    /// scrollback are untouched either way.
    func sendHold(_ command: HoldCommand) {
        controlChannel?.hold(command)
    }

    /// The surface's live grid and cell, read from libghostty
    /// (`ghostty_surface_size`) rather than from the action-delivered
    /// `state.cellSize`, so the clamp and the cell divisor come from the same
    /// snapshot. `nil` before the surface exists or before its first layout.
    func surfaceGeometry() -> (grid: MouseForwarding.GridSize, cellPixels: (width: Int, height: Int))? {
        guard let surface else { return nil }
        let size = ghostty_surface_size(surface)
        guard size.columns > 0, size.rows > 0, size.cell_width_px > 0, size.cell_height_px > 0 else { return nil }
        return (
            MouseForwarding.GridSize(columns: Int(size.columns), rows: Int(size.rows)),
            (Int(size.cell_width_px), Int(size.cell_height_px))
        )
    }

    func openHoveredLink() {
        guard let url = state.hoveredLinkURL, let value = URL(string: url) else { return }
        NSWorkspace.shared.open(value)
    }

    func searchFor(_ needle: String) {
        perform(action: "search:\(needle)")
    }

    func navigateSearch(forward: Bool) {
        perform(action: forward ? "navigate_search:next" : "navigate_search:previous")
    }

    /// Closes the bar here as well as in libghostty: its own `END_SEARCH`
    /// answer is what closes it for Esc in the terminal, but a surface that is
    /// already gone never sends one.
    func endSearch() {
        perform(action: "end_search")
        search.close()
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
    /// so a theme OR font-size change repaints every pane without tearing
    /// its bridge down. A font-size change recomputes the surface's cell
    /// size and, with it, its grid from the view's unchanged pixel size
    /// (`Surface.zig`'s `setFontSize` -> `setCellSize`); the resulting PTY
    /// winsize change reaches herdr through the bridge's SIGWINCH like any
    /// other. Ported from Herdglass's `TerminalSession.updateConfig`
    /// (BSL-1.1, attributed): push, then re-apply the light/dark scheme the
    /// same way `attach` does, since a config push does not imply one.
    @discardableResult
    func updateAppearance(_ colors: GhosttyThemeColors, fontSizePoints: Double, optionAsAlt: OptionAsAlt) -> Bool {
        configuration.themeColors = colors
        configuration.fontSizePoints = fontSizePoints
        configuration.optionAsAlt = optionAsAlt
        guard let surface else { return false }
        guard host.updateLiveConfig(
            surface: surface, colors: colors, commandArgv: configuration.commandArgv,
            fontFamily: TerminalFont.face, fontSizePoints: fontSizePoints, optionAsAlt: optionAsAlt
        ) else {
            return false
        }
        lastVerifiedGrid = nil
        applyColorScheme(appearance: view?.effectiveAppearance)
        requestRender()
        verifyExpectedGrid()
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

    /// the surface's child process going away (for any reason -- the
    /// bridge exiting because the herdr binary could not be resolved, the
    /// control child dying before its first repaint, a crash) must not leave
    /// a cold pane's status card up forever waiting for a `first_frame` line
    /// that will now never arrive. Latching here reveals whatever the
    /// surface actually shows (even blank) instead; idempotent past the
    /// first call, same as every other path into `markFirstFrameReceived()`.
    func handleCloseRequest(processAlive: Bool) {
        markFirstFrameReceived()
        closeHandler?(processAlive)
    }

    /// Surface-targeted actions. The window/tab/split ones are the shell's to
    /// decide -- this app draws what the server reports -- so they are
    /// dropped rather than handled.
    func handle(_ action: ghostty_action_s, text: String?) {
        switch action.tag {
        case GHOSTTY_ACTION_RENDER:
            requestRender()
            reportScreenActivityIfDue()
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
        case GHOSTTY_ACTION_START_SEARCH:
            search.open(needle: text)
        case GHOSTTY_ACTION_END_SEARCH:
            search.close()
        case GHOSTTY_ACTION_SEARCH_TOTAL:
            search.report(total: Int(action.action.search_total.total))
        case GHOSTTY_ACTION_SEARCH_SELECTED:
            search.report(selected: Int(action.action.search_selected.selected))
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
        // The one command a flock surface's child ever needs travels
        // through the app-config workaround, not through this struct's
        // `command` field below (see `GhosttyHost.configureNextSurface`'s
        // doc comment for why the field alone does nothing). This has to run
        // before `ghostty_surface_new`, not after: the surface reads the
        // app's config once, at creation.
        guard host.configureNextSurface(
            colors: configuration.themeColors, commandArgv: configuration.commandArgv,
            fontFamily: TerminalFont.face, fontSizePoints: configuration.fontSizePoints,
            optionAsAlt: configuration.optionAsAlt
        ) else { return }

        if let scheme = colorScheme(for: view.effectiveAppearance) {
            ghostty_app_set_color_scheme(app, scheme)
        }

        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(view).toOpaque()))
        config.userdata = Unmanaged.passUnretained(self).toOpaque()
        config.scale_factor = Double(scale)
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

    /// `.other` carries AppKit's own `buttonNumber`, so it goes through the
    /// shared table (`GhosttyMouseButtons`, unit-tested in `FlockCoreTests`).
    private func translate(_ button: GhosttySurfaceView.MouseButton) -> ghostty_input_mouse_button_e {
        switch button {
        case .left: return GHOSTTY_MOUSE_LEFT
        case .right: return GHOSTTY_MOUSE_RIGHT
        case .other(let number): return GhosttyMouseButtons.translate(buttonNumber: number)
        }
    }

    /// AppKit's flags mapped into `GhosttyKeyModifiers`, then through
    /// `GhosttyKeyMods.translate` (pure, unit-tested in `FlockCoreTests`)
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
