// Portions derived from Herdglass (BSL-1.1), Sources/Herdglass/Ghostty/TerminalSurfaceView.swift.
import AppKit
import GhosttyKit
import PaddockCore

/// The `NSView` libghostty draws a surface into, and the AppKit end of its
/// input: keys (including input methods), mouse, scroll and the context menu.
@MainActor
final class GhosttySurfaceView: NSView, @preconcurrency NSTextInputClient {
    enum MouseButton: Equatable {
        case left
        case right
        /// AppKit's `buttonNumber`, so 2 is the middle button.
        case other(Int)
    }

    let session: GhosttySession

    /// A left click landed here. In a split that is how the active pane
    /// changes, so it has to be seen outside libghostty as well.
    var onPrimaryClick: (() -> Void)?

    /// Builds the pane's right-click menu on demand, read by `menu(for:)`.
    /// `nil` (a placeholder host view with no pane context) means no menu.
    var paneMenuProvider: (() -> NSMenu?)?

    private var trackingArea: NSTrackingArea?
    private var markedText = NSMutableAttributedString()
    /// Collects what `interpretKeyEvents` produces during one `keyDown`, so
    /// the key and its text reach libghostty together.
    private var keyTextAccumulator: [String]?
    private var pendingRenderRequest = false
    private var isRendering = false
    private var observedWindow: NSWindow?
    private var cursorHidden = false
    nonisolated(unsafe) private var windowObservers: [NSObjectProtocol] = []
    nonisolated(unsafe) private var globalObservers: [NSObjectProtocol] = []
    /// Whether this view should grab real AppKit key focus as soon as it has
    /// a window. Set by `GhosttySurfaceRepresentable` from the pane's
    /// resolved-focused state. Read (not just written) from `updateNSView`
    /// too, so a later flip while the view already has a window still takes
    /// effect -- but `viewDidMoveToWindow` is the primary trigger: it is the
    /// only place guaranteed to run exactly when `window` first becomes
    /// non-nil, which `updateNSView` is not (`updateNSView`'s
    /// own focus request runs once, immediately after `makeNSView`, with
    /// `window` still nil -- silently lost, never retried, because nothing
    /// about this representable's inputs changes again after that to trigger
    /// a second `updateNSView` call).
    var wantsFocus = false
    /// Where the matching mouse-DOWN actually sent a button, read back by the
    /// UP so it always replays the SAME destination -- never re-derived from
    /// `wantsFocus`/capture at up-time, which can have changed in between (a
    /// focus flip or a capture toggle mid-click) and would otherwise strand
    /// the release: a libghostty button left stuck down, or an app that got a
    /// down over the FIFO but never its up.
    private enum ButtonRoute {
        /// The DOWN was sent to the pane's own program as a `terminal.mouse`
        /// line; its UP must go there too.
        case app
        /// The DOWN went into libghostty via `ghostty_surface_mouse_button`;
        /// its UP must too.
        case surface
    }
    private var leftButtonRoute: ButtonRoute?
    private var rightButtonRoute: ButtonRoute?
    private var rightButtonDownDisposition: RightClickDisposition = .menu
    private var otherButtonRoutes: [Int: ButtonRoute] = [:]
    /// Whole-cell wheel steps, accumulated the same way whether the tick ends
    /// up going to the app (under capture) or to herdr's real viewport
    /// (capture off); reset by `mouseCaptureDidEnd` so a momentum tail never
    /// emits after the app stopped listening.
    private var scrollAccumulator = ScrollAccumulator()

    /// The surface is born at libghostty's own internal placeholder size
    /// (`ghostty_surface_config_s` has no size field), so the initial frame
    /// here is just this view's own starting point before its first real
    /// layout; `session.resize(to:)` (called from `attach` and from
    /// `layout()`) is what makes the surface agree with it.
    init(session: GhosttySession) {
        self.session = session
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        applyBackgroundColor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        let notificationCenter = NotificationCenter.default
        for observer in windowObservers + globalObservers {
            notificationCenter.removeObserver(observer)
        }
    }

    override var acceptsFirstResponder: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The surface is created here rather than at init: libghostty builds a
    /// `CVDisplayLink` from the view's screen, so there has to be a window
    /// first. `attach` is idempotent, so a nil surface (no window/screen yet,
    /// or a locked screen) is retried automatically the next time this fires
    /// or `layout()` runs -- there is no separate polling/retry timer.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateObservers()
        applyBackgroundColor()
        if window == nil { return }
        session.attach(to: self)
        renderIfNeeded()
        if wantsFocus, window?.firstResponder !== self {
            requestFocus()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        session.updateContentScale()
        session.setDisplayID(currentDisplayID())
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyBackgroundColor()
        session.applyColorScheme(appearance: effectiveAppearance)
    }

    override func updateLayer() {
        requestRender()
    }

    override func layout() {
        super.layout()
        session.resize(to: bounds.size)
    }

    override func becomeFirstResponder() -> Bool {
        session.setFocused(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        session.setFocused(false)
        return true
    }

    // MARK: - Mouse

    /// `onPrimaryClick` fires only while `!wantsFocus` -- it is how herdr
    /// focus ever moves to an UNFOCUSED pane at all (the header row has its
    /// own tap gesture; the body does not). An ALREADY-focused pane's body
    /// click (including a drag-select's own mouse-down) must never repeat
    /// it: `jumpToHerdr(pane:)` issues a real `pane.focus` RPC every call,
    /// so firing it on every click into a pane the user is already working
    /// in would mean a `pane.focus` round trip per click/select-drag with
    /// no purpose. Everything past this -- grabbing AppKit first responder,
    /// forwarding the click into libghostty -- is separately gated on
    /// `wantsFocus`: an unfocused pane's body click only asks
    /// `SessionViewModel` to move focus there, and never simultaneously
    /// steals AppKit's first-responder status out from under whichever pane
    /// truly holds it right now.
    override func mouseDown(with event: NSEvent) {
        guard wantsFocus else {
            leftButtonRoute = nil
            onPrimaryClick?()
            return
        }
        requestWindowFirstResponder()
        leftButtonRoute = sendButtonDown(.left, event: event)
    }

    override func mouseUp(with event: NSEvent) {
        sendButtonUp(.left, event: event, route: leftButtonRoute)
        leftButtonRoute = nil
    }

    /// Right-clicks land in the focused pane by default and Option summons the
    /// herdr action menu -- see `RightClickDisposition.decide` for the full
    /// rule: the focused pane whose app has claimed the mouse forwards a plain
    /// right-click to the pane; Option, a plain shell (capture off), or any
    /// pane that is not paddock's focused one gets the menu instead. The menu
    /// itself comes from `menu(for:)` below (built by `paneMenuProvider`),
    /// reached by handing the event back to the responder chain (`super`);
    /// libghostty's own context menu is never shown here.
    override func rightMouseDown(with event: NSEvent) {
        let disposition = RightClickDisposition.decide(
            optionHeld: event.modifierFlags.contains(.option),
            captureEnabled: session.mouseCaptureEnabled,
            paneIsFocused: wantsFocus
        )
        rightButtonDownDisposition = disposition
        switch disposition {
        case .menu:
            rightButtonRoute = nil
            super.rightMouseDown(with: event)
        case .forwardToPane:
            requestWindowFirstResponder()
            rightButtonRoute = sendButtonDown(.right, event: event)
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        switch rightButtonDownDisposition {
        case .menu:
            super.rightMouseUp(with: event)
        case .forwardToPane:
            sendButtonUp(.right, event: event, route: rightButtonRoute)
        }
        rightButtonRoute = nil
    }

    /// Supplies the `.menu`-disposition right-click's `NSMenu`: AppKit calls
    /// this itself once `rightMouseDown`'s `super` call reaches the
    /// responder-chain context-menu machinery. Every pane is this view, so
    /// without this override AppKit gets `nil` here (the `NSView` default)
    /// and no menu, and no `.contextMenu`, ever appears.
    override func menu(for event: NSEvent) -> NSMenu? {
        paneMenuProvider?()
    }

    override func otherMouseDown(with event: NSEvent) {
        guard wantsFocus else { return }
        requestWindowFirstResponder()
        let number = Int(event.buttonNumber)
        otherButtonRoutes[number] = sendButtonDown(otherButton(number), event: event, appkitNumber: number)
    }

    override func otherMouseUp(with event: NSEvent) {
        let number = Int(event.buttonNumber)
        guard let route = otherButtonRoutes.removeValue(forKey: number) else { return }
        sendButtonUp(otherButton(number), event: event, route: route, appkitNumber: number)
    }

    override func mouseEntered(with event: NSEvent) { session.sendMousePosition(event) }
    override func mouseExited(with event: NSEvent) { session.sendMouseExit(modifiers: event.modifierFlags) }

    /// Under capture the app owns the pointer, so motion becomes a
    /// `terminal.mouse` moved line (herdr drops it unless the app enabled
    /// any-motion tracking). Otherwise, unfocused panes included, it stays a
    /// libghostty position update: hover links and the pointer shape are
    /// local surface state, not pane input, so `.drop` still feeds them.
    override func mouseMoved(with event: NSEvent) {
        switch mouseDecision(kind: .moved, button: nil, event: event) {
        case .toApp(let command): session.sendPaneMouse(command)
        // `.toHerdrScroll` is unreachable for `.moved` (`decide` only ever
        // returns it for a scroll kind), kept here only for exhaustiveness.
        case .toSurface, .drop, .toHerdrScroll: session.sendMousePosition(event)
        }
    }

    /// A drag belongs to whatever its button's DOWN decided, kept in step
    /// with the down/up pairing: an app-routed drag becomes a `terminal.mouse`
    /// drag line, a surface-routed one stays a libghostty position update
    /// (that is how libghostty extends a selection).
    override func mouseDragged(with event: NSEvent) {
        sendDrag(.left, event: event, route: leftButtonRoute)
    }

    override func rightMouseDragged(with event: NSEvent) {
        sendDrag(.right, event: event, route: rightButtonRoute)
    }

    override func otherMouseDragged(with event: NSEvent) {
        let number = Int(event.buttonNumber)
        sendDrag(otherButton(number), event: event, route: otherButtonRoutes[number])
    }

    /// Under capture a wheel gesture becomes whole-cell `terminal.mouse`
    /// scroll lines for the pane's own program, one per cell crossed via
    /// `ScrollAccumulator`, mirroring libghostty's own report cadence.
    /// Capture off routes the SAME per-cell steps to herdr's real,
    /// shared viewport instead (`terminal.scroll`, vertical only -- herdr has
    /// no horizontal wire form, so horizontal wheel motion with capture off
    /// is simply dropped): libghostty holds no scrollback of its own any
    /// more for this to fall back to, since herdr streams viewport repaints,
    /// not a retainable scrollback. An unfocused pane drops the wheel
    /// entirely, same as every other mouse event.
    override func scrollWheel(with event: NSEvent) {
        guard let cell = cellSizeInPoints() else {
            scrollAccumulator.reset()
            return
        }
        let steps = scrollAccumulator.add(
            deltaX: Double(event.scrollingDeltaX), deltaY: Double(event.scrollingDeltaY),
            precise: event.hasPreciseScrollingDeltas, cellSize: cell
        )
        routeScrollSteps(steps.y, positive: .scrollUp, negative: .scrollDown, event: event)
        routeScrollSteps(steps.x, positive: .scrollLeft, negative: .scrollRight, event: event)
    }

    /// Called by the session on a capture on -> off transition.
    func mouseCaptureDidEnd() {
        scrollAccumulator.reset()
    }

    // MARK: - Mouse forwarding helpers

    /// Routes one axis's whole-cell step count for a wheel event: `.toApp`
    /// replays the same `terminal.mouse` command once per cell crossed
    /// (matching the prior per-tick cadence); `.toHerdrScroll` sends ONE
    /// `terminal.scroll` line carrying the whole step count, since herdr's
    /// viewport move is a single line-count command, not a per-cell repeat.
    private func routeScrollSteps(
        _ steps: Int, positive: MouseForwarding.EventKind, negative: MouseForwarding.EventKind, event: NSEvent
    ) {
        guard steps != 0 else { return }
        let kind = steps > 0 ? positive : negative
        switch mouseDecision(kind: kind, button: nil, event: event, lines: abs(steps)) {
        case .toHerdrScroll(let direction, let lines):
            session.sendPaneScroll(direction: direction, lines: lines)
        case .toApp:
            guard let command = mouseCommand(kind: kind, button: nil, event: event) else { return }
            for _ in 0..<abs(steps) {
                session.sendPaneMouse(command)
            }
        case .toSurface, .drop:
            break
        }
    }

    private func sendDrag(_ button: MouseForwarding.Button, event: NSEvent, route: ButtonRoute?) {
        switch route {
        case .app:
            if let command = mouseCommand(kind: .drag, button: button, event: event) {
                session.sendPaneMouse(command)
            }
        case .surface, nil:
            session.sendMousePosition(event)
        }
    }

    private func otherButton(_ appkitNumber: Int) -> MouseForwarding.Button {
        appkitNumber == 2 ? .middle : .other(appkitNumber)
    }

    /// Routes a button DOWN through `MouseForwarding` and performs it, then
    /// returns where it went so the matching UP can replay the same
    /// destination. `appkitNumber` is AppKit's own `buttonNumber` for the
    /// surface path's `.other(n)` (nil for left/right, whose surface enum
    /// cases are fixed).
    private func sendButtonDown(_ button: MouseForwarding.Button, event: NSEvent, appkitNumber: Int? = nil) -> ButtonRoute? {
        switch mouseDecision(kind: .down, button: button, event: event) {
        case .toApp(let command):
            session.sendPaneMouse(command)
            return .app
        case .toSurface:
            session.sendMousePosition(event)
            session.sendMouseButton(surfaceButton(button, appkitNumber: appkitNumber), pressed: true, event: event)
            return .surface
        // Unreachable for `.down` (`decide` only ever returns this for a
        // scroll kind), kept here only for exhaustiveness.
        case .toHerdrScroll, .drop:
            return nil
        }
    }

    private func sendButtonUp(_ button: MouseForwarding.Button, event: NSEvent, route: ButtonRoute?, appkitNumber: Int? = nil) {
        switch route {
        case .app:
            if let command = mouseCommand(kind: .up, button: button, event: event) {
                session.sendPaneMouse(command)
            }
        case .surface:
            session.sendMousePosition(event)
            session.sendMouseButton(surfaceButton(button, appkitNumber: appkitNumber), pressed: false, event: event)
        case nil:
            break
        }
    }

    private func surfaceButton(_ button: MouseForwarding.Button, appkitNumber: Int?) -> MouseButton {
        switch button {
        case .left: return .left
        case .right: return .right
        case .middle: return .other(appkitNumber ?? 2)
        case .other(let number): return .other(number)
        }
    }

    private func mouseDecision(kind: MouseForwarding.EventKind, button: MouseForwarding.Button?, event: NSEvent, lines: Int = 1) -> MouseForwarding.Decision {
        MouseForwarding.decide(
            kind: kind, button: button, modifiers: crosstermModifiers(event.modifierFlags),
            point: forwardingPoint(event), cellSize: cellSizeInPoints(), grid: session.surfaceGeometry()?.grid,
            captureEnabled: session.mouseCaptureEnabled, paneIsFocused: wantsFocus,
            shiftHeld: event.modifierFlags.contains(.shift), lines: lines
        )
    }

    private func mouseCommand(kind: MouseForwarding.EventKind, button: MouseForwarding.Button?, event: NSEvent, lines: Int = 1) -> MouseForwarding.Command? {
        MouseForwarding.command(
            kind: kind, button: button, modifiers: crosstermModifiers(event.modifierFlags),
            point: forwardingPoint(event), cellSize: cellSizeInPoints(), grid: session.surfaceGeometry()?.grid,
            lines: lines
        )
    }

    private func crosstermModifiers(_ flags: NSEvent.ModifierFlags) -> UInt8 {
        MouseForwarding.crosstermModifiers(
            shift: flags.contains(.shift), control: flags.contains(.control),
            option: flags.contains(.option), command: flags.contains(.command)
        )
    }

    /// The click point in the surface's top-left-origin point space -- the
    /// same y-flip `GhosttySession.sendMousePosition` applies for
    /// `ghostty_surface_mouse_pos`, so app and surface see one coordinate
    /// system. Origin 0 is the grid's origin because the scratch config
    /// zeroes libghostty's window padding (`GhosttyThemeConfig`).
    private func forwardingPoint(_ event: NSEvent) -> MouseForwarding.Point {
        let point = convert(event.locationInWindow, from: nil)
        return MouseForwarding.Point(x: Double(point.x), y: Double(bounds.height - point.y))
    }

    /// One cell in view POINTS: libghostty sizes the surface and reports its
    /// cell in pixels (`ghostty_surface_size`), but the click point above is
    /// in points, so the pixel cell is divided by the backing scale to match.
    /// `nil` until the surface has laid out; `MouseForwarding` then falls back
    /// to the surface path rather than fabricate a cell.
    private func cellSizeInPoints() -> MouseForwarding.CellSize? {
        guard let geometry = session.surfaceGeometry() else { return nil }
        let scale = Double(window?.backingScaleFactor ?? window?.screen?.backingScaleFactor ?? 2)
        guard scale > 0 else { return nil }
        return MouseForwarding.CellSize(
            width: Double(geometry.cellPixels.width) / scale, height: Double(geometry.cellPixels.height) / scale
        )
    }

    // MARK: - Keyboard

    /// Gated on `wantsFocus`, not just on AppKit first-responder status: every
    /// pane holds a live control bridge, so this gate is what keeps a
    /// keystroke out of a pane the user is not in. `requestWindowFirst
    /// Responder` no longer runs for an unfocused pane, so this should be
    /// unreachable in practice -- kept as defense in depth against AppKit
    /// assigning first responder some other way (window activation, Tab
    /// navigation) this view does not control.
    override func keyDown(with event: NSEvent) {
        guard InputSinkDisposition.decide(wantsFocus: wantsFocus) == .deliver else { return }
        // `keyDown` (never `flagsChanged`) is by construction real key input,
        // not a bare modifier change -- the one exception is a Command combo
        // (the system's to handle, not a sign the user started typing into
        // this pane).
        if !event.modifierFlags.contains(.command) {
            session.onUserInput?()
        }
        keyTextAccumulator = []
        interpretKeyEvents([event])
        let text = keyTextAccumulator?.joined()
        keyTextAccumulator = nil
        session.sendKeyDown(event, text: text?.isEmpty == true ? nil : text)
    }

    override func keyUp(with event: NSEvent) {
        session.sendKeyUp(event)
    }

    override func flagsChanged(with event: NSEvent) {
        session.sendMousePosition(event)
        super.flagsChanged(with: event)
    }

    override func doCommand(by selector: Selector) {
        if session.performCommand(selector) {
            return
        }
        // Everything the terminal handles itself: letting AppKit also insert
        // a newline or move the insertion point would double the keystroke.
        if Self.shouldSuppressSystemTextInputCommand(selector) {
            return
        }
        super.doCommand(by: selector)
    }

    // MARK: - Menu actions

    @objc func copy(_ sender: Any?) {
        session.copySelection()
    }

    /// Gated on the same disposition as `keyDown`: a paste is input for the
    /// pane's program exactly like a keystroke is, and AppKit can route
    /// Cmd+V here through a first responder this view did not ask for.
    @objc func paste(_ sender: Any?) {
        guard InputSinkDisposition.decide(wantsFocus: wantsFocus) == .deliver else { return }
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        session.paste(text)
    }

    override func selectAll(_ sender: Any?) {
        session.perform(action: "select_all")
    }

    @objc func openHoveredLink(_ sender: Any?) {
        session.openHoveredLink()
    }

    @objc func copyHoveredLink(_ sender: Any?) {
        guard let url = session.state.hoveredLinkURL, !url.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        isMenuActionEnabled(menuItem.action)
    }

    // MARK: - NSTextInputClient

    func hasMarkedText() -> Bool {
        markedText.length > 0
    }

    func markedRange() -> NSRange {
        hasMarkedText() ? NSRange(location: 0, length: markedText.length) : NSRange(location: NSNotFound, length: 0)
    }

    func selectedRange() -> NSRange {
        NSRange(location: NSNotFound, length: 0)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let text = Self.plainString(from: string) ?? ""
        markedText = NSMutableAttributedString(string: text)
        session.setMarkedText(text.isEmpty ? nil : text)
    }

    func unmarkText() {
        markedText = NSMutableAttributedString()
        session.setMarkedText(nil)
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    func characterIndex(for point: NSPoint) -> Int { 0 }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window else { return .zero }
        return window.convertToScreen(convert(bounds, to: nil))
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard InputSinkDisposition.decide(wantsFocus: wantsFocus) == .deliver else { return }
        guard let text = Self.plainString(from: string) else { return }
        unmarkText()
        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(text)
        } else {
            session.insertText(text)
        }
    }

    // MARK: - Rendering and cursor

    func requestFocus() {
        requestWindowFirstResponder()
    }

    /// Coalesces the render requests libghostty makes from its own thread
    /// into one draw per pass, and never re-enters one already in progress.
    func requestRender() {
        pendingRenderRequest = true
        needsDisplay = true
        layer?.setNeedsDisplay()
        renderIfNeeded()
    }

    func applyCursor(for shape: ghostty_action_mouse_shape_e) {
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_TEXT,
             GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT:
            NSCursor.iBeam.set()
        case GHOSTTY_MOUSE_SHAPE_POINTER:
            NSCursor.pointingHand.set()
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR:
            NSCursor.crosshair.set()
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED,
             GHOSTTY_MOUSE_SHAPE_NO_DROP:
            NSCursor.operationNotAllowed.set()
        case GHOSTTY_MOUSE_SHAPE_COL_RESIZE,
             GHOSTTY_MOUSE_SHAPE_EW_RESIZE:
            NSCursor.resizeLeftRight.set()
        case GHOSTTY_MOUSE_SHAPE_ROW_RESIZE,
             GHOSTTY_MOUSE_SHAPE_NS_RESIZE:
            NSCursor.resizeUpDown.set()
        case GHOSTTY_MOUSE_SHAPE_GRAB,
             GHOSTTY_MOUSE_SHAPE_GRABBING:
            NSCursor.openHand.set()
        default:
            NSCursor.arrow.set()
        }
    }

    func setCursorHidden(_ hidden: Bool) {
        guard cursorHidden != hidden else { return }
        cursorHidden = hidden
        NSCursor.setHiddenUntilMouseMoves(hidden)
    }

    static func shouldSuppressSystemTextInputCommand(_ selector: Selector) -> Bool {
        selector == #selector(NSResponder.insertNewline(_:))
            || selector == #selector(NSResponder.insertLineBreak(_:))
            || selector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))
            || selector == #selector(NSResponder.insertTab(_:))
            || selector == #selector(NSResponder.insertBacktab(_:))
            || selector == #selector(NSResponder.deleteBackward(_:))
            || selector == #selector(NSResponder.deleteForward(_:))
            || selector == #selector(NSResponder.deleteWordBackward(_:))
            || selector == #selector(NSResponder.deleteWordForward(_:))
            || selector == #selector(NSResponder.deleteToBeginningOfLine(_:))
            || selector == #selector(NSResponder.deleteToEndOfLine(_:))
            || selector == #selector(NSResponder.moveUp(_:))
            || selector == #selector(NSResponder.moveDown(_:))
            || selector == #selector(NSResponder.moveLeft(_:))
            || selector == #selector(NSResponder.moveRight(_:))
            || selector == #selector(NSResponder.moveWordLeft(_:))
            || selector == #selector(NSResponder.moveWordRight(_:))
            || selector == #selector(NSResponder.moveToBeginningOfLine(_:))
            || selector == #selector(NSResponder.moveToEndOfLine(_:))
            || selector == #selector(NSResponder.pageUp(_:))
            || selector == #selector(NSResponder.pageDown(_:))
            || selector == #selector(NSResponder.cancelOperation(_:))
    }

    // MARK: - Private

    /// The padding libghostty leaves around the grid is this layer, so it has
    /// to be the terminal's background rather than a color of the view's
    /// own. Doubles as this session's placeholder: with no surface yet (or
    /// no surface at all, e.g. between attaches), this background color is
    /// the entire picture -- no separate placeholder view or spinner.
    private func applyBackgroundColor() {
        layer?.backgroundColor = NSColor(session.configuration.themeColors.background).cgColor
    }

    private func renderIfNeeded() {
        guard !isRendering else { return }
        while pendingRenderRequest {
            pendingRenderRequest = false
            isRendering = true
            session.render()
            isRendering = false
        }
    }

    private func updateObservers() {
        let notificationCenter = NotificationCenter.default
        if observedWindow !== window {
            for observer in windowObservers {
                notificationCenter.removeObserver(observer)
            }
            windowObservers.removeAll()
            observedWindow = window

            if let window {
                windowObservers.append(
                    notificationCenter.addObserver(
                        forName: NSWindow.didChangeOcclusionStateNotification,
                        object: window,
                        queue: .main
                    ) { [weak self] _ in
                        Task { @MainActor [weak self] in
                            self?.session.setOccluded(!window.occlusionState.contains(.visible))
                        }
                    }
                )
                windowObservers.append(
                    notificationCenter.addObserver(
                        forName: NSWindow.didChangeScreenNotification,
                        object: window,
                        queue: .main
                    ) { [weak self] _ in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            self.session.setDisplayID(self.currentDisplayID())
                        }
                    }
                )
            }
        }

        if globalObservers.isEmpty {
            globalObservers.append(
                notificationCenter.addObserver(
                    forName: NSTextInputContext.keyboardSelectionDidChangeNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.session.keyboardLayoutChanged()
                    }
                }
            )
        }
    }

    /// Gated on `wantsFocus` here, once, rather than at each call site: no
    /// caller -- a mouse-down, `requestFocus()`, `viewDidMoveToWindow` --
    /// may ever move real AppKit first-responder status onto a pane that is
    /// not the resolved-focused one, or the wrong pane's surface starts
    /// reporting itself focused (`becomeFirstResponder` -> `session.
    /// setFocused(true)`) and taking the keystrokes meant for the pane the
    /// user is actually in.
    private func requestWindowFirstResponder() {
        guard InputSinkDisposition.decide(wantsFocus: wantsFocus) == .deliver else { return }
        guard let window else { return }
        if !window.isKeyWindow {
            window.makeKeyAndOrderFront(nil)
        }
        if window.firstResponder !== self {
            window.makeFirstResponder(self)
        }
    }

    private func currentDisplayID() -> CGDirectDisplayID? {
        guard let screenNumber = window?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(screenNumber.uint32Value)
    }

    private func isMenuActionEnabled(_ action: Selector?) -> Bool {
        switch action {
        case #selector(copy(_:)):
            return session.hasSelection()
        case #selector(paste(_:)):
            return NSPasteboard.general.string(forType: .string) != nil
        case #selector(selectAll(_:)):
            return true
        case #selector(openHoveredLink(_:)), #selector(copyHoveredLink(_:)):
            return session.state.hoveredLinkURL?.isEmpty == false
        default:
            return false
        }
    }

    private static func plainString(from string: Any) -> String? {
        switch string {
        case let string as String:
            return string
        case let attributed as NSAttributedString:
            return attributed.string
        default:
            return nil
        }
    }
}

extension NSColor {
    /// Converts a `GhosttyThemeColor` (PaddockCore, no AppKit) into an
    /// `NSColor` for the one place the view actually paints with it.
    convenience init(_ color: GhosttyThemeColor) {
        self.init(
            srgbRed: CGFloat(color.red) / 255,
            green: CGFloat(color.green) / 255,
            blue: CGFloat(color.blue) / 255,
            alpha: 1
        )
    }
}
