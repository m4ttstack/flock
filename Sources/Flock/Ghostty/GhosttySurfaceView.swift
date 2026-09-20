// Portions derived from Herdglass (BSL-1.1), Sources/Herdglass/Ghostty/TerminalSurfaceView.swift.
import AppKit
import GhosttyKit
import FlockCore

/// The `NSView` libghostty draws a surface into, and the AppKit end of its
/// input: keys (including input methods), mouse, scroll and the context menu.
@MainActor
final class GhosttySurfaceView: NSView, @preconcurrency NSTextInputClient, @preconcurrency NSMenuItemValidation {
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

    /// The pane body's end of the drag layer, called once per drag with the
    /// press point in this view's own TOP-LEFT space. Everything after that
    /// belongs to `DragCoordinator`, which drives the drag off window-level
    /// monitors: the body reports the start and nothing else, so a drag
    /// survives this view being torn down mid-gesture.
    var onBodyDragBegan: ((CGPoint) -> Void)?

    private var trackingArea: NSTrackingArea?
    private var markedText = NSMutableAttributedString()
    /// Collects what `interpretKeyEvents` produces during one `keyDown`, so
    /// the key and its text reach libghostty together.
    private var keyTextAccumulator: [String]?
    private var pendingRenderRequest = false
    private var isRendering = false
    private var observedWindow: NSWindow?
    private var cursorHidden = false
    /// The last shape libghostty itself asked for, independent of whatever
    /// `cursorUpdate(with:)` is currently painting over it -- what restores
    /// the terminal's own cursor once rearrange mode ends, with no new
    /// libghostty callback required to re-derive it.
    private var lastLibghosttyCursor: NSCursor?
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
    /// Set by `GhosttySurfaceRepresentable` from `RearrangeMode.active`.
    /// While true, `mouseDecision` forces every `MouseForwarding` result to
    /// `.drop` and `rightMouseDown` forces `RightClickDisposition` to
    /// `.suppressed`: the whole pane is a drag surface, so no mouse event
    /// reaches the app or libghostty's own surface.
    ///
    /// The cursor is set here directly when the pointer is already over this
    /// view: a `.cursorUpdate` tracking area only fires on ENTERING the area,
    /// and `invalidateCursorRects` re-runs cursor rects, not tracking-area
    /// cursor updates, so a mode flip with the pointer resting on the pane
    /// would otherwise leave the old cursor showing until it left and came
    /// back.
    var rearrangeActive = false {
        didSet {
            guard rearrangeActive != oldValue else { return }
            if pointerIsInside { applyPaneCursor() }
        }
    }
    /// Set by `GhosttySurfaceRepresentable` from
    /// `DragCoordinator.isPaneDragInFlight`. The closed-hand cursor for the
    /// drag itself comes from that coordinator's own `NSCursor.push`/`pop`,
    /// which holds regardless of pointer motion; this only stops a stray
    /// `cursorUpdate` (AppKit's cursor-rect events are unreliable but not
    /// impossible while a mouse button is held) from painting over it.
    var paneDragInProgress = false
    /// Set by `GhosttySurfaceRepresentable` from
    /// `SessionViewModel.isPristineLauncherPane`. While true this view
    /// claims no point at all -- see `hitTest(_:)`.
    var isPristineLauncherPane = false
    /// Set by `GhosttySurfaceRepresentable` from
    /// `SessionViewModel.renameTarget`. While true this view holds no first
    /// responder of its own and takes none -- see `syncFocusClaim()`.
    var editorIsOpen = false
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
    /// A press the body took as its own. Only rearrange mode produces one, and
    /// nothing is routed anywhere for it: no terminal input, and no
    /// `onPrimaryClick` for an unfocused pane either.
    private struct PendingGrab {
        let origin: CGPoint
        var isDragging = false
    }
    private var pendingGrab: PendingGrab?
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

    /// `PaneLauncherOverlay` draws its button row in SwiftUI ABOVE this real
    /// `NSView`, and AppKit hit-testing hands a click to the frontmost NSView
    /// SUBVIEW under the point regardless of what SwiftUI painted over it --
    /// so without this, a pristine pane's surface eats every click a
    /// launcher button was meant to receive. Returning `nil` here makes the
    /// containing hosting view fall through to its own SwiftUI content for
    /// this whole view's bounds, buttons and the space around them alike.
    override func hitTest(_ point: NSPoint) -> NSView? {
        isPristineLauncherPane ? nil : super.hitTest(point)
    }

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
        syncFocusClaim()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved, .cursorUpdate],
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
        // Checked before anything is routed: while rearranging, the whole
        // pane is a drag surface, so an unfocused pane's first click starts a
        // drag rather than firing `onPrimaryClick`'s real `pane.focus` RPC. At
        // rest the body is the terminal's, down to its first line: the drag
        // handle there is the cell's own top chrome, which is SwiftUI.
        if PaneGrabRegion.bodyArmsDrag(at: topLeftPoint(event), in: topLeftBounds, rearrangeActive: rearrangeActive) {
            pendingGrab = PendingGrab(origin: topLeftPoint(event))
            leftButtonRoute = nil
            return
        }
        guard wantsFocus else {
            leftButtonRoute = nil
            onPrimaryClick?()
            return
        }
        // Gated here, not inside `requestWindowFirstResponder` itself: that
        // helper also backs `requestFocus()`'s non-mouse callers (a
        // resolved-focus change following the view, `viewDidMoveToWindow`),
        // which must keep working during rearrange.
        if !rearrangeActive {
            requestWindowFirstResponder()
        }
        leftButtonRoute = sendButtonDown(.left, event: event)
    }

    override func mouseUp(with event: NSEvent) {
        // A grab that never travelled far enough is simply nothing: rearrange
        // mode routes no mouse event to the terminal or the app, so there is
        // no click to replay. The drag itself, if it started, is ended by the
        // coordinator's own monitor, not here.
        if pendingGrab != nil {
            pendingGrab = nil
            return
        }
        sendButtonUp(.left, event: event, route: leftButtonRoute)
        leftButtonRoute = nil
    }

    /// Right-clicks land in the focused pane by default and Option summons the
    /// herdr action menu -- see `RightClickDisposition.decide` for the full
    /// rule: the focused pane whose app has claimed the mouse forwards a plain
    /// right-click to the pane; Option, a plain shell (capture off), or any
    /// pane that is not flock's focused one gets the menu instead. The menu
    /// itself comes from `menu(for:)` below (built by `paneMenuProvider`),
    /// reached by handing the event back to the responder chain (`super`);
    /// libghostty's own context menu is never shown here.
    override func rightMouseDown(with event: NSEvent) {
        let disposition = RightClickDisposition.decide(
            optionHeld: event.modifierFlags.contains(.option),
            captureEnabled: session.mouseCaptureEnabled,
            paneIsFocused: wantsFocus,
            rearrangeActive: rearrangeActive
        )
        rightButtonDownDisposition = disposition
        switch disposition {
        case .menu:
            rightButtonRoute = nil
            super.rightMouseDown(with: event)
        case .forwardToPane:
            requestWindowFirstResponder()
            rightButtonRoute = sendButtonDown(.right, event: event)
        case .suppressed:
            rightButtonRoute = nil
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        switch rightButtonDownDisposition {
        case .menu:
            super.rightMouseUp(with: event)
        case .forwardToPane:
            sendButtonUp(.right, event: event, route: rightButtonRoute)
        case .suppressed:
            break
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
        if !rearrangeActive {
            requestWindowFirstResponder()
        }
        let number = Int(event.buttonNumber)
        otherButtonRoutes[number] = sendButtonDown(otherButton(number), event: event, appkitNumber: number)
    }

    override func otherMouseUp(with event: NSEvent) {
        let number = Int(event.buttonNumber)
        guard let route = otherButtonRoutes.removeValue(forKey: number) else { return }
        sendButtonUp(otherButton(number), event: event, route: route, appkitNumber: number)
    }

    override func mouseEntered(with event: NSEvent) {
        guard !rearrangeActive else {
            applyPaneCursor()
            return
        }
        session.sendMousePosition(event)
    }
    override func mouseExited(with event: NSEvent) { session.sendMouseExit(modifiers: event.modifierFlags) }

    /// Under capture the app owns the pointer, so motion becomes a
    /// `terminal.mouse` moved line (herdr drops it unless the app enabled
    /// any-motion tracking). Otherwise, unfocused panes included, it stays a
    /// libghostty position update: hover links and the pointer shape are
    /// local surface state, not pane input, so `.drop` still feeds them --
    /// EXCEPT while rearranging, where `.drop` means something stronger
    /// (nothing reaches the terminal, full stop), so that case is checked
    /// first and separately rather than folded into the existing `.drop`
    /// branch below.
    override func mouseMoved(with event: NSEvent) {
        // No cursor-update event fires for motion WITHIN a tracking area, so
        // the open hand is re-asserted here or anything that set another
        // cursor mid-hover would stick.
        guard !rearrangeActive else {
            applyPaneCursor()
            return
        }
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
        if var grab = pendingGrab {
            if !grab.isDragging, DragThreshold.passed(from: grab.origin, to: topLeftPoint(event)) {
                grab.isDragging = true
                pendingGrab = grab
                onBodyDragBegan?(grab.origin)
            }
            return
        }
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
    ///
    /// The chosen speed decides how many cells the gesture crossed, upstream
    /// of that fork, so both routes carry it: a wheel that moved one pane's
    /// program further than it moved herdr's viewport would read as a bug.
    override func scrollWheel(with event: NSEvent) {
        guard let cell = cellSizeInPoints() else {
            scrollAccumulator.reset()
            return
        }
        let steps = scrollAccumulator.add(
            deltaX: Double(event.scrollingDeltaX), deltaY: Double(event.scrollingDeltaY),
            precise: event.hasPreciseScrollingDeltas, cellSize: cell, speed: session.scrollSpeed()
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

    /// `route` is already `nil` under rearrange (the DOWN that would have set
    /// it went `.drop`), but the `.surface, nil` branch below exists for the
    /// ordinary unfocused-pane case too and still calls `sendMousePosition` --
    /// so rearrange is checked explicitly here rather than folded into that
    /// fallback, the same reasoning as `mouseMoved`.
    private func sendDrag(_ button: MouseForwarding.Button, event: NSEvent, route: ButtonRoute?) {
        guard !rearrangeActive else { return }
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
            shiftHeld: event.modifierFlags.contains(.shift), lines: lines, rearrangeActive: rearrangeActive
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

    /// The event's location in this view's own space with the origin flipped
    /// to TOP-LEFT: the drag layer works in one top-left space throughout, so
    /// AppKit's bottom-left origin stops here and never leaves this file.
    private func topLeftPoint(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: point.x, y: bounds.height - point.y)
    }

    private var topLeftBounds: CGRect {
        CGRect(origin: .zero, size: bounds.size)
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

    /// Ungated where `keyDown` is gated, and deliberately so: `wantsFocus` can
    /// flip between a press and its release, and a release withheld from a
    /// surface that took the press leaves that key held down inside
    /// libghostty. It is the same rule `ButtonRoute` states for the mouse --
    /// an up replays where its down went, never where focus is now.
    override func keyUp(with event: NSEvent) {
        session.sendKeyUp(event)
    }

    /// Forwards no key input at all: it refreshes the modifiers libghostty
    /// carries with the POINTER, which `mouseMoved` and `mouseEntered` update
    /// for an unfocused pane too.
    override func flagsChanged(with event: NSEvent) {
        session.sendMousePosition(event)
        super.flagsChanged(with: event)
    }

    override func doCommand(by selector: Selector) {
        // `keyDown` has already forwarded the event to the terminal, so every
        // command AppKit derives from it is a duplicate, whether or not this
        // view recognizes the selector. Passing an unrecognized one to
        // `super` reaches `noResponder(for:)`, which beeps at a keystroke the
        // pane's program has in fact received (upstream ghostty's surface
        // never calls `super` here for the same reason).
        _ = session.performCommand(selector)
    }

    // MARK: - Menu actions

    @objc func copy(_ sender: Any?) {
        session.copySelection()
    }

    /// Where Cmd+V lands once the menu bar's Paste item (`PasteboardCommands`)
    /// sends `paste(_:)` down the responder chain and this view is the first
    /// responder -- which it only is when this is the focused pane and no
    /// rename editor is up.
    ///
    /// Gated on the same disposition as `keyDown`: a paste is input for the
    /// pane's program exactly like a keystroke is, and AppKit can route
    /// Cmd+V here through a first responder this view did not ask for.
    ///
    /// `session.paste` is the one road a paste takes out of flock, whether it
    /// started here or at libghostty's own `paste_from_clipboard` binding
    /// (`GhosttyHost`'s read-clipboard callback, which routes to this same
    /// method).
    @objc func paste(_ sender: Any?) {
        guard InputSinkDisposition.decide(wantsFocus: wantsFocus) == .deliver else { return }
        guard let text = NSPasteboard.general.pasteText() else { return }
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

    /// Reached only through `NSMenuItemValidation`: without the conformance
    /// this method is invisible to the Objective-C runtime, AppKit's
    /// `respondsToSelector:` check fails, and every item it means to speak for
    /// falls back to AppKit's default "enabled because something answers the
    /// action".
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

    /// The terminal's own dealings with the window's first responder: run as
    /// this pane becomes the focused one
    /// (`GhosttySurfaceRepresentable.updateNSView`) and as its view enters a
    /// window (`viewDidMoveToWindow`), never on behalf of a click.
    /// `TerminalFocusClaim` decides all of it, so both call sites take the
    /// same rule -- including the standing down that hands an opening editor
    /// a window with no first responder, which is the state its own focus
    /// request is answered from.
    ///
    /// A click still moves first responder here (`mouseDown` calls the
    /// responder grab directly), which is how an open editor gets dismissed
    /// at all.
    func syncFocusClaim() {
        guard let window else { return }
        switch TerminalFocusClaim.decide(
            wantsFocus: wantsFocus, editorIsOpen: editorIsOpen, holdsResponder: window.firstResponder === self
        ) {
        case .claim:
            requestWindowFirstResponder()
        case .standDown:
            // Checked, not discarded: a refused stand-down leaves this view
            // holding the keyboard with an editor open over it, which is the
            // defect this whole path exists to end, and it would otherwise
            // retry every pass and read exactly like never having run at all.
            // Debug-only, and the e2e runs Debug: nothing here can refuse in
            // practice, since a window always accepts becoming its own first
            // responder and this view's own `resignFirstResponder` never says
            // no.
            if !window.makeFirstResponder(nil) {
                assertionFailure("a window refused to take back first responder from a pane with an editor open")
            }
        case .leaveAlone:
            break
        }
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
        let cursor: NSCursor
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_TEXT,
             GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT:
            cursor = .iBeam
        case GHOSTTY_MOUSE_SHAPE_POINTER:
            cursor = .pointingHand
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR:
            cursor = .crosshair
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED,
             GHOSTTY_MOUSE_SHAPE_NO_DROP:
            cursor = .operationNotAllowed
        case GHOSTTY_MOUSE_SHAPE_COL_RESIZE,
             GHOSTTY_MOUSE_SHAPE_EW_RESIZE:
            cursor = .resizeLeftRight
        case GHOSTTY_MOUSE_SHAPE_ROW_RESIZE,
             GHOSTTY_MOUSE_SHAPE_NS_RESIZE:
            cursor = .resizeUpDown
        case GHOSTTY_MOUSE_SHAPE_GRAB,
             GHOSTTY_MOUSE_SHAPE_GRABBING:
            cursor = .openHand
        default:
            cursor = .arrow
        }
        lastLibghosttyCursor = cursor
        // Rearrange mode and an in-flight pane drag both own the cursor for
        // as long as they last (the whole body reads as a grab handle, or a
        // drag already forced closed-hand everywhere); a stray libghostty
        // shape callback painting over either would fight them. `mouseMoved`
        // already withholds `sendMousePosition` during rearrange, so this
        // guard mostly matters for a shape callback that fires from
        // something other than pointer motion.
        guard !rearrangeActive, !paneDragInProgress else { return }
        cursor.set()
    }

    /// Fires on entering this view's tracking area.
    override func cursorUpdate(with event: NSEvent) {
        applyPaneCursor()
    }

    private func applyPaneCursor() {
        switch PaneCursor.forPaneBody(rearrangeActive: rearrangeActive, paneDragInProgress: paneDragInProgress) {
        case .closedHand:
            // `DragCoordinator` already pushed the closed-hand cursor for
            // the whole app; setting it again here would repaint over that
            // push with nothing to pop it back off.
            break
        case .openHand:
            NSCursor.openHand.set()
        case .passthrough:
            (lastLibghosttyCursor ?? NSCursor.arrow).set()
        }
    }

    private var pointerIsInside: Bool {
        guard let window else { return false }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return visibleRect.contains(point)
    }

    func setCursorHidden(_ hidden: Bool) {
        guard cursorHidden != hidden else { return }
        cursorHidden = hidden
        NSCursor.setHiddenUntilMouseMoves(hidden)
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
                            // The window's new screen can carry a different
                            // backing scale than the one it left, and nothing
                            // else observes a single window moving screens.
                            self.session.updateContentScale()
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
            return NSPasteboard.general.offersPasteText
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
    /// Converts a `GhosttyThemeColor` (FlockCore, no AppKit) into an
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
