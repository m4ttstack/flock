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
    /// non-nil, which `updateNSView` is not (confirmed live: `updateNSView`'s
    /// own focus request ran once, immediately after `makeNSView`, with
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

    /// Wired by `GhosttySurfaceRepresentable` from the pane cell's own
    /// `BrowserScrollState` and reveal/exit closures.
    var onScrollPastTop: (() -> Void)?
    var onScrollBackToLive: (() -> Void)?
    var browserState: BrowserScrollState?
    private var lastEdgeSignal = Date.distantPast
    /// `nonisolated(unsafe)`, matching `windowObservers`/`globalObservers`
    /// above: `deinit` is not actor-isolated, so the monitor cleanup there
    /// needs to reach this property from a nonisolated context.
    nonisolated(unsafe) private var scrollEdgeMonitor: Any?

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
        if let scrollEdgeMonitor { NSEvent.removeMonitor(scrollEdgeMonitor) }
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
        if window == nil {
            if let scrollEdgeMonitor { NSEvent.removeMonitor(scrollEdgeMonitor) }
            scrollEdgeMonitor = nil
            return
        }
        if scrollEdgeMonitor == nil {
            scrollEdgeMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handleScrollEdge(event)
                return event
            }
        }
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

    /// Right-clicks land in the pane by default and Option summons the herdr
    /// action menu -- see `RightClickDisposition.decide` for the full rule
    /// (Matt's): a control-mode pane whose app has claimed the mouse forwards
    /// a plain right-click to the pane; Option, a plain shell (capture off),
    /// or an observe-mode pane all get the menu instead. The menu is
    /// presented by SwiftUI's `.contextMenu` on `PaneCellView`, reached by
    /// handing the event back to the responder chain (`super`); libghostty's
    /// own context menu is never shown here. `mode` is `wantsFocus`-derived
    /// because the resolved-focused pane is the only one ever in `.control`.
    override func rightMouseDown(with event: NSEvent) {
        let disposition = RightClickDisposition.decide(
            optionHeld: event.modifierFlags.contains(.option),
            captureEnabled: session.mouseCaptureEnabled,
            mode: wantsFocus ? .control : .observe
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
    /// any-motion tracking); otherwise it stays a libghostty position update
    /// for hover/link detection and selection.
    override func mouseMoved(with event: NSEvent) {
        switch mouseDecision(kind: .moved, button: nil, event: event) {
        case .toApp(let command): session.sendPaneMouse(command)
        case .toSurface: session.sendMousePosition(event)
        case .drop: break
        }
    }

    /// A drag belongs to whatever the left DOWN decided, kept in step with
    /// the down/up pairing: an app-routed drag becomes a `terminal.mouse`
    /// drag line, a surface-routed one stays a libghostty position update
    /// (that is how libghostty extends a selection).
    override func mouseDragged(with event: NSEvent) {
        switch leftButtonRoute {
        case .app:
            if let command = mouseCommand(kind: .drag, button: .left, event: event) {
                session.sendPaneMouse(command)
            }
        case .surface, nil:
            session.sendMousePosition(event)
        }
    }

    override func rightMouseDragged(with event: NSEvent) { session.sendMousePosition(event) }
    override func otherMouseDragged(with event: NSEvent) { session.sendMousePosition(event) }

    /// Under capture a wheel gesture becomes a `terminal.mouse` scroll line
    /// for the pane's own program (never `terminal.scroll`, which mutates the
    /// shared herdr viewport); otherwise it stays local to libghostty's own
    /// scrollback, as it always has.
    override func scrollWheel(with event: NSEvent) {
        let deltaY = event.scrollingDeltaY
        let deltaX = event.scrollingDeltaX
        let kind: MouseForwarding.EventKind?
        if abs(deltaY) >= abs(deltaX) {
            kind = deltaY > 0 ? .scrollUp : (deltaY < 0 ? .scrollDown : nil)
        } else {
            kind = deltaX > 0 ? .scrollLeft : (deltaX < 0 ? .scrollRight : nil)
        }
        if let kind, case .toApp(let command) = mouseDecision(kind: kind, button: nil, event: event) {
            session.sendPaneMouse(command)
            return
        }
        session.sendScrollWheel(event)
    }

    // MARK: - Mouse forwarding helpers

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
        case .drop:
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
            point: forwardingPoint(event), cellSize: cellSizeInPoints(),
            captureEnabled: session.mouseCaptureEnabled, mode: wantsFocus ? .control : .observe,
            shiftHeld: event.modifierFlags.contains(.shift), lines: lines
        )
    }

    private func mouseCommand(kind: MouseForwarding.EventKind, button: MouseForwarding.Button?, event: NSEvent, lines: Int = 1) -> MouseForwarding.Command? {
        MouseForwarding.command(
            kind: kind, button: button, modifiers: crosstermModifiers(event.modifierFlags),
            point: forwardingPoint(event), cellSize: cellSizeInPoints(), lines: lines
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
    /// system.
    private func forwardingPoint(_ event: NSEvent) -> MouseForwarding.Point {
        let point = convert(event.locationInWindow, from: nil)
        return MouseForwarding.Point(x: Double(point.x), y: Double(bounds.height - point.y))
    }

    /// One cell in view POINTS: libghostty reports the cell in pixels
    /// (`GHOSTTY_ACTION_CELL_SIZE`), and the surface is sized in pixels
    /// (`bounds * scale`), but the click point above is in points, so the
    /// pixel cell is divided by the backing scale to match. `nil` until the
    /// first cell-size action arrives; `MouseForwarding` then falls back to
    /// the surface path rather than fabricate a cell.
    private func cellSizeInPoints() -> MouseForwarding.CellSize? {
        guard let cell = session.state.cellSize, cell.width > 0, cell.height > 0 else { return nil }
        let scale = Double(window?.backingScaleFactor ?? window?.screen?.backingScaleFactor ?? 2)
        guard scale > 0 else { return nil }
        return MouseForwarding.CellSize(width: Double(cell.width) / scale, height: Double(cell.height) / scale)
    }

    /// Deep history reveals by intent: an up-scroll while
    /// already at the very top signals past-the-top; a down-scroll while the
    /// browser sits at its live end signals back-to-live. `scrollWheel`
    /// above is never called at all once the browser overlay is topmost
    /// (its own SwiftUI `ScrollView` wins the hit test then), so a LOCAL
    /// event monitor -- observing before dispatch, added/removed alongside
    /// the window in `viewDidMoveToWindow` -- is the only way to see the
    /// gesture in both states; returning the event unmodified means
    /// libghostty (or the overlay) still receives it untouched. libghostty
    /// exposes no synchronous scroll-position read, only the
    /// action-delivered `GHOSTTY_ACTION_SCROLLBAR` offset on `session.state`,
    /// so "at top" can lag a wheel tick behind a fast flick -- a missed tick
    /// only delays the reveal by one more tick of continued scrolling, never
    /// triggers a wrong one.
    private func handleScrollEdge(_ event: NSEvent) {
        // Under capture the wheel is the app's, forwarded as a
        // `terminal.mouse` scroll line; libghostty's own scrollback never
        // moves, so a deep-history reveal here would fight the pane's program.
        guard !session.mouseCaptureEnabled else { return }
        guard event.window === window else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        let deltaY = event.scrollingDeltaY
        guard deltaY != 0, Date().timeIntervalSince(lastEdgeSignal) > 0.25 else { return }
        let scrollingUp = deltaY > 0
        if let browserState, browserState.browsing {
            if !scrollingUp, browserState.atLiveEnd {
                lastEdgeSignal = Date()
                onScrollBackToLive?()
            }
            return
        }
        if scrollingUp, session.state.isAtScrollbackTop {
            lastEdgeSignal = Date()
            onScrollPastTop?()
        }
    }

    // MARK: - Keyboard

    /// Gated on `wantsFocus`, not just on AppKit first-responder status: the
    /// view-layer half of the three independent unfocused-input guards (the
    /// other two are the bridge dropping stdin in observe mode, and herdr
    /// giving an observe client no input path at all). `requestWindowFirst
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

    @objc func paste(_ sender: Any?) {
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
    /// setFocused(true)`) while still sitting on an observe-mode bridge that
    /// drops every keystroke this then routes to it.
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
