import AppKit
import Carbon.HIToolbox
import Observation
import PaddockCore
import SwiftUI

/// What the commit seam returned, tagged with the drag that asked. Two things
/// need it: `.committed` and `.noOp` both leave `DragController.phase` at
/// `.idle` and only one of them earns a flash, and a slow commit can resolve
/// after a second drag has already started.
@MainActor
final class DragOutcomeRelay {
    struct Record {
        let generation: Int
        let outcome: DragOutcome
    }

    var generation = 0
    var last: Record?
}

/// Tells the coordinator a spring load fired, inside the controller call that
/// fired it. The controller needs the closure before the coordinator's own
/// initializer has finished, so it goes through this box.
@MainActor
final class SpringLoadRelay {
    var fired: (() -> Void)?
}

/// The one place the drag gestures, the live layout, and `DragController`
/// meet.
///
/// A drag in flight belongs to this object, not to the view it started from.
/// The views only ever START a drag; move, end, cancel and every piece of
/// teardown run off window-level event monitors here. That is what makes a
/// spring-load reveal survivable: revealing another tab destroys the pane
/// cell the drag began on, and a gesture that owned its own lifecycle would
/// be torn down with no end event, stranding the ghost, the monitors, and the
/// rearrange hold for the rest of the session.
@MainActor
@Observable
final class DragCoordinator {
    /// The floating proxy: a title, a glyph, and the size of the item it
    /// stands for (which `DragVisuals.ghostSize` scales down).
    struct Ghost: Equatable {
        let title: String
        let symbol: String
        let originSize: CGSize
    }

    /// A committed drop's landing zone while it flashes.
    struct LandingFlash: Equatable {
        let id: UUID
        let rect: CGRect
    }

    struct InsertionMark: Equatable {
        let bar: CGRect
        let dot: CGRect
    }

    let controller: DragController

    private(set) var ghost: Ghost?
    /// The subject for as long as its ghost is on screen, settle included:
    /// `controller.phase` is already back to `.idle` while the spring runs,
    /// and the origin must stay faded until the ghost is gone.
    private(set) var activeSubject: DragSubject?
    /// The resolved target, stored rather than read back off
    /// `controller.phase`. The phase is reassigned on every pointer move
    /// because it carries the ghost position, so a view that read the target
    /// through it would re-evaluate per move even when the target had not
    /// changed. Writing it only on a real change is what keeps the dropzone
    /// preview's tree transform and layout pass off the move path.
    private(set) var target: DropTarget?
    /// The ghost's own top-left, held as state rather than derived from the
    /// phase: the phase is `.committing` for as long as the drop takes to
    /// execute, and a ghost derived from it would vanish for that stretch and
    /// reappear at the destination with no spring to ride.
    private(set) var ghostTopLeft: CGPoint?
    /// True only while the settle spring runs, which is the one stretch the
    /// ghost's position is animated at all.
    private(set) var isSettling = false
    private(set) var landingFlash: LandingFlash?
    /// True from a PANE drag's own start (past the movement threshold, never
    /// for a tab/workspace drag) until its teardown, settle animation
    /// excluded -- exactly the span the closed-hand cursor covers. A
    /// dedicated flag rather than `activeSubject != nil`: that stays set
    /// through the settle spring, which is no longer "in flight."
    private(set) var isPaneDragInFlight = false

    // MARK: - Live surfaces, every frame in the drag space

    var canvas = CanvasGeometry.empty
    var stripWorkspace: WorkspaceID?
    var stripFrame: CGRect?
    /// Where the strip's trailing readout begins, which is as far right as the
    /// new-tab zone may reach.
    var stripTrailingLimit: CGFloat?
    var railFrame: CGRect?

    /// Neither zone is a button: each is the free run its chrome already has,
    /// so they move with the items rather than being published separately and
    /// going stale behind them. Which subjects may use them is
    /// `resolveDropTarget`'s decision, not this one's.
    var newTabZone: CGRect? {
        guard let stripFrame else { return nil }
        return DropZones.trailing(
            in: stripFrame, itemsEndingAt: tabFrames.last?.frame.maxX, before: stripTrailingLimit ?? stripFrame.maxX
        )
    }

    var newWorkspaceZone: CGRect? {
        guard let railFrame else { return nil }
        return DropZones.below(in: railFrame, itemsEndingAt: workspaceFrames.last?.frame.maxY)
    }

    /// The strip's and the rail's scroll views, which is where their items are
    /// actually visible once either list overflows.
    var stripViewport: CGRect?
    var railViewport: CGRect?

    /// Frames arrive one item at a time as each row lays out, so the strip and
    /// the rail publish their ORDER separately; that order is what turns the
    /// frames back into a list, and it is also what drops an item's stale
    /// frame once the item itself is gone. Each list's frames are held in its
    /// scroll content's own space, so a scroll moves them without a report.
    private var tabItems = ScrolledItemFrames<TabID>()
    private var workspaceItems = ScrolledItemFrames<WorkspaceID>()

    var tabOrder: [TabID] { tabItems.order }
    var workspaceOrder: [WorkspaceID] { workspaceItems.order }

    /// Set by the strip and the rail; each scrolls its own list to an offset.
    @ObservationIgnored var stripScroller: ((CGFloat) -> Void)?
    @ObservationIgnored var railScroller: ((CGFloat) -> Void)?
    @ObservationIgnored private var stripScrollExtent = (offset: CGFloat(0), maximum: CGFloat(0))
    @ObservationIgnored private var railScrollExtent = (offset: CGFloat(0), maximum: CGFloat(0))

    /// An `NSView` laid out at exactly the drag space's own frame, so a raw
    /// AppKit event location becomes a drag-space point without this file
    /// assuming anything about where the SwiftUI root sits in the window.
    @ObservationIgnored weak var spaceAnchor: NSView?

    @ObservationIgnored private let toasts: ToastCenter
    @ObservationIgnored private let rearrangeMode: RearrangeMode
    @ObservationIgnored private let outcomes = DragOutcomeRelay()
    @ObservationIgnored private let springLoads = SpringLoadRelay()
    /// The tick decision lives in `AutoScroller`; this only owns the display
    /// link that asks it once per frame.
    @ObservationIgnored private var autoScroller = AutoScroller()
    @ObservationIgnored private let autoScrollTicker = AutoScrollTicker()
    /// Where the pointer last was. A list auto-scrolling under a pointer that
    /// has stopped moving delivers no events, so each tick resolves the drop
    /// again from here.
    @ObservationIgnored private var lastPointer: CGPoint?
    /// Which life the current gesture is in, and the gate that makes a second
    /// arm for one press a no-op. Pure, so its truth table is tested in
    /// `DragGestureMachineTests` rather than argued about here.
    @ObservationIgnored private var machine = DragGestureMachine()
    /// Bumped by every `begin` and `cancel`, so a commit that resolves after
    /// the gesture it belongs to is over cannot flash a stale rect or settle
    /// the ghost a later gesture is holding.
    @ObservationIgnored private var generation = 0
    /// Where the gesture started, for the cancel spring-back.
    @ObservationIgnored private var grabPoint: CGPoint = .zero
    /// Whether this drag is the one holding rearrange mode open. Only a drag
    /// that STARTED in rearrange mode does: the hold exists so releasing
    /// Control mid-drag does not repaint the panes, and a chrome drag at rest
    /// has no rearrange paint to hold on to in the first place.
    @ObservationIgnored private var holdsRearrangeOpen = false
    /// Read from `deinit`, which runs outside actor isolation for a
    /// `@MainActor` class -- the same pattern `RearrangeMode` uses for its own
    /// event monitor.
    @ObservationIgnored nonisolated(unsafe) private var eventMonitor: Any?
    @ObservationIgnored nonisolated(unsafe) private var resignObserver: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var windowCloseObserver: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var selectionMonitor: Any?
    @ObservationIgnored nonisolated(unsafe) private var selectionResignObserver: NSObjectProtocol?

    /// The rail's Cmd+click selection. Every decision lives in
    /// `WorkspaceSelection`; this only feeds it the presses, keys, app
    /// deactivation and drag ends it decides on.
    private(set) var workspaceSelection = WorkspaceSelection()
    @ObservationIgnored private var settleTask: Task<Void, Never>?
    @ObservationIgnored private var flashTask: Task<Void, Never>?

    init(
        toasts: ToastCenter,
        rearrangeMode: RearrangeMode,
        commit: @escaping DragCommit,
        springLoadAction: @escaping SpringLoadAction
    ) {
        self.toasts = toasts
        self.rearrangeMode = rearrangeMode
        let outcomes = self.outcomes
        let springLoads = self.springLoads
        controller = DragController(
            commit: { subject, target in
                // Sampled BEFORE the await, which is the whole point of the
                // relay: a slow commit can resolve after a later drag has
                // already bumped the counter, and reading it on the way out
                // would tag the reply with that later drag's number.
                let issuedBy = outcomes.generation
                let outcome = await commit(subject, target)
                outcomes.last = DragOutcomeRelay.Record(generation: issuedBy, outcome: outcome)
                return outcome
            },
            springLoadAction: springLoadAction,
            onSpringLoad: { _ in springLoads.fired?() }
        )
        springLoads.fired = { [weak self] in self?.springLoadFired() }
    }

    deinit {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
        }
        if let windowCloseObserver {
            NotificationCenter.default.removeObserver(windowCloseObserver)
        }
        if let selectionMonitor {
            NSEvent.removeMonitor(selectionMonitor)
        }
        if let selectionResignObserver {
            NotificationCenter.default.removeObserver(selectionResignObserver)
        }
    }

    // MARK: - Surface registration

    /// On screen, in the drag space: content frames placed through wherever
    /// the list has scrolled to.
    var tabFrames: [TabItemFrame] {
        tabItems.onScreen.map { TabItemFrame(id: $0.id, frame: $0.frame) }
    }

    var workspaceFrames: [WorkspaceItemFrame] {
        workspaceItems.onScreen.map { WorkspaceItemFrame(id: $0.id, frame: $0.frame) }
    }

    func setTabOrder(_ order: [TabID]) {
        writeIfChanged(\.tabItems) { $0.setOrder(order) }
    }

    func setWorkspaceOrder(_ order: [WorkspaceID]) {
        guard workspaceOrder != order else { return }
        writeIfChanged(\.workspaceItems) { $0.setOrder(order) }
        updateSelection { $0.retain(order) }
    }

    /// Frozen while that list is showing an insertion gap: the index is
    /// measured against where the items REST, so a reshuffled item must never
    /// be able to report its shifted position back in and move the very gap
    /// that shifted it. Neither reorder target is spring-load eligible, so
    /// nothing else can change either list while one is frozen. The frame is
    /// in the strip's content space, so the freeze never stops a scroll from
    /// moving it on screen.
    func setTabFrame(_ frame: CGRect, for id: TabID) {
        guard !isReorderingTabs else { return }
        writeIfChanged(\.tabItems) { $0.setContentFrame(frame, for: id) }
    }

    func setWorkspaceFrame(_ frame: CGRect, for id: WorkspaceID) {
        guard !isReorderingWorkspaces else { return }
        writeIfChanged(\.workspaceItems) { $0.setContentFrame(frame, for: id) }
    }

    func setStripContentOrigin(_ origin: CGPoint) {
        writeIfChanged(\.tabItems) { $0.setContentOrigin(origin) }
    }

    func setRailContentOrigin(_ origin: CGPoint) {
        writeIfChanged(\.workspaceItems) { $0.setContentOrigin(origin) }
    }

    func setStripScroll(offset: CGFloat, maximumOffset: CGFloat) {
        stripScrollExtent = (offset, maximumOffset)
    }

    func setRailScroll(offset: CGFloat, maximumOffset: CGFloat) {
        railScrollExtent = (offset, maximumOffset)
    }

    /// An observed property notifies on every write, equal value or not, and
    /// a frame report that changes nothing must not re-render every row.
    private func writeIfChanged<ID>(
        _ keyPath: ReferenceWritableKeyPath<DragCoordinator, ScrolledItemFrames<ID>>,
        _ change: (inout ScrolledItemFrames<ID>) -> Bool
    ) {
        var copy = self[keyPath: keyPath]
        guard change(&copy) else { return }
        self[keyPath: keyPath] = copy
    }

    private var isReorderingTabs: Bool {
        if case .tabStrip? = target { return true }
        return false
    }

    private var isReorderingWorkspaces: Bool {
        if case .workspaceRail? = target { return true }
        return false
    }

    var surfaces: DropSurfaces? {
        guard let stripWorkspace else { return nil }
        return DropSurfaces(
            canvas: canvas,
            stripWorkspace: stripWorkspace,
            tabFrames: tabFrames,
            workspaceFrames: workspaceFrames,
            stripFrame: stripFrame,
            railFrame: railFrame,
            stripViewport: stripViewport,
            railViewport: railViewport,
            newTabZone: newTabZone,
            newWorkspaceZone: newWorkspaceZone
        )
    }

    // MARK: - Gesture lifecycle

    /// The only entry point a view has. A second caller for the same press
    /// (the pane body's AppKit path and a SwiftUI gesture both seeing it, say)
    /// finds the gesture already live and does nothing, so no view needs a
    /// latch of its own to remember what it started.
    func beginIfIdle(_ subject: DragSubject, ghost: Ghost, at point: CGPoint) {
        guard machine.handle(.begin) == .start else { return }
        generation += 1
        outcomes.generation = generation
        settleTask?.cancel()
        isSettling = false
        grabPoint = point
        activeSubject = subject
        self.ghost = ghost
        ghostTopLeft = ghostTopLeft(centeredOn: point)
        controller.began(subject, at: point)
        target = nil
        // Global, not per-view: a per-view cursor rect would have to be
        // re-entered to repaint, and the pointer is usually over some OTHER
        // pane by the time this matters -- `push` forces the image
        // regardless of what is under the pointer, for as long as this drag
        // lasts. Only a pane drag gets it; a tab/workspace drag keeps
        // whatever cursor it already had.
        if case .pane = subject {
            isPaneDragInFlight = true
            NSCursor.closedHand.push()
        }
        holdsRearrangeOpen = rearrangeMode.active
        if holdsRearrangeOpen {
            rearrangeMode.dragBegan()
        }
        installMonitors()
    }

    private func move(to point: CGPoint) {
        guard machine.tracksMotion else { return }
        lastPointer = point
        resolve(at: point)
        updateAutoScroll(pointer: point)
    }

    private func resolve(at point: CGPoint) {
        ghostTopLeft = ghostTopLeft(centeredOn: point)
        guard let surfaces else { return }
        controller.moved(to: point, surfaces: surfaces)
        let resolved: DropTarget?
        if case .dragging(_, _, let current) = controller.phase {
            resolved = current
        } else {
            resolved = nil
        }
        if target != resolved {
            target = resolved
        }
    }

    private func end() {
        let landingTarget = target
        teardown()
        finishWorkspaceSelection()
        guard case .dragging = controller.phase else {
            settle(to: ghostTopLeft(centeredOn: grabPoint))
            return
        }
        let surfaces = surfaces
        let settleRect = landingTarget.flatMap { resolved in surfaces.flatMap { dropTargetRect(for: resolved, surfaces: $0) } }
        let flashRect = landingTarget.flatMap { resolved in surfaces.flatMap { dropFlashRect(for: resolved, surfaces: $0) } }
        let started = generation
        Task { [weak self] in
            await self?.controller.ended()
            guard let self, self.generation == started else { return }
            self.finish(settleRect: settleRect, flashRect: flashRect, generation: started)
        }
    }

    /// Esc. The drag is over immediately, but the button is still down, so the
    /// monitors stay installed to catch the release that returns this to idle.
    private func cancel() {
        guard machine.handle(.cancel) == .cancel else { return }
        generation += 1
        teardown(keepingMonitors: true)
        finishWorkspaceSelection()
        controller.cancelled()
        settle(to: ghostTopLeft(centeredOn: grabPoint))
    }

    /// The app went inactive or the window closed with the button still down,
    /// so no `leftMouseUp` is ever coming to this window. Same teardown as
    /// Esc, but the gesture ends outright rather than waiting for a release
    /// that will not arrive.
    private func abandon() {
        guard machine.handle(.abandon) == .cancel else {
            removeMonitors()
            return
        }
        generation += 1
        teardown()
        controller.cancelled()
        settle(to: ghostTopLeft(centeredOn: grabPoint))
    }

    private func release() {
        guard machine.handle(.release) == .end else {
            removeMonitors()
            return
        }
        end()
    }

    /// Everything that must stop the moment a drag stops, whatever ended it.
    private func teardown(keepingMonitors: Bool = false) {
        if !keepingMonitors {
            removeMonitors()
        }
        stopAutoScroll()
        target = nil
        releaseRearrangeHold()
        // The one choke point every exit path (`end`, `cancel`, `abandon`)
        // runs through, so the pop is always paired with the push above --
        // never duplicated per exit path, which is how a stray unbalanced
        // pop or a stuck closed-hand cursor would sneak in.
        if isPaneDragInFlight {
            isPaneDragInFlight = false
            NSCursor.pop()
        }
    }

    /// Settles the phase back to rest and sends the ghost where the outcome
    /// says it belongs: into the landing zone it actually reached, or home.
    private func finish(settleRect: CGRect?, flashRect: CGRect?, generation: Int) {
        if case .rejected(let reason) = controller.phase {
            report(reason)
            // The only public way back to `.idle` from `.rejected`, and it
            // issues no commit of its own.
            controller.cancelled()
            settle(to: ghostTopLeft(centeredOn: grabPoint))
            return
        }
        guard outcomes.last?.generation == generation, outcomes.last?.outcome == .committed else {
            settle(to: ghostTopLeft(centeredOn: grabPoint))
            return
        }
        if let flashRect {
            flash(flashRect)
        }
        settle(to: settleRect?.origin ?? ghostTopLeft(centeredOn: grabPoint))
    }

    private func releaseRearrangeHold() {
        guard holdsRearrangeOpen else { return }
        holdsRearrangeOpen = false
        rearrangeMode.dragEnded()
    }

    /// The ghost's top-left for a pointer at `point`, sized from whatever
    /// this drag is carrying. A drag with no ghost yet cannot be positioned
    /// against one, so the pointer itself is the answer.
    private func ghostTopLeft(centeredOn point: CGPoint) -> CGPoint {
        guard let ghost else { return point }
        return DragVisuals.ghostTopLeft(
            forCursor: point, ghostSize: DragVisuals.ghostSize(forOrigin: ghost.originSize)
        )
    }

    private func settle(to topLeft: CGPoint) {
        isSettling = true
        ghostTopLeft = topLeft
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(DragVisuals.settleDuration))
            guard !Task.isCancelled else { return }
            self?.clearGhost()
        }
    }

    private func clearGhost() {
        ghost = nil
        activeSubject = nil
        ghostTopLeft = nil
        isSettling = false
    }

    private func flash(_ rect: CGRect) {
        let mark = LandingFlash(id: UUID(), rect: rect)
        landingFlash = mark
        flashTask?.cancel()
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(DragVisuals.landingFlashDuration))
            guard !Task.isCancelled, self?.landingFlash == mark else { return }
            self?.landingFlash = nil
        }
    }

    /// The commit seam's own notice sink already posted this exact reason
    /// through the same single-slot toast center; re-posting it would only
    /// restart the pill's entry transition.
    private func report(_ reason: String) {
        guard toasts.current?.message != reason else { return }
        toasts.show(reason, kind: .info)
    }

    // MARK: - The drag's own event monitors

    /// Installed for the length of the drag and no longer. Mouse events are
    /// passed through rather than swallowed, so AppKit's and SwiftUI's own
    /// state machines still close out normally; the views simply do not act
    /// on them.
    private func installMonitors() {
        if eventMonitor == nil {
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
                guard let self else { return event }
                switch event.type {
                case .keyDown:
                    switch Int(event.keyCode) {
                    case kVK_Escape:
                        self.cancel()
                        return nil
                    case kVK_Space:
                        self.controller.forceSpringLoad()
                        return nil
                    default:
                        return event
                    }
                case .leftMouseDragged:
                    if let point = self.dragSpacePoint(event) {
                        self.move(to: point)
                    }
                    return event
                case .leftMouseUp:
                    self.release()
                    return event
                default:
                    return event
                }
            }
        }
        if resignObserver == nil {
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.abandon() }
            }
        }
        if windowCloseObserver == nil, let window = spaceAnchor?.window {
            windowCloseObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.abandon() }
            }
        }
    }

    private func removeMonitors() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        eventMonitor = nil
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
        }
        resignObserver = nil
        if let windowCloseObserver {
            NotificationCenter.default.removeObserver(windowCloseObserver)
        }
        windowCloseObserver = nil
    }

    // MARK: - Edge auto-scroll

    private var scrollRegions: [AutoScroller.Region] {
        var regions: [AutoScroller.Region] = []
        if let stripViewport {
            regions.append(AutoScroller.Region(
                surface: .strip, viewport: stripViewport, axis: .horizontal,
                offset: stripScrollExtent.offset, maximumOffset: stripScrollExtent.maximum
            ))
        }
        if let railViewport {
            regions.append(AutoScroller.Region(
                surface: .rail, viewport: railViewport, axis: .vertical,
                offset: railScrollExtent.offset, maximumOffset: railScrollExtent.maximum
            ))
        }
        return regions
    }

    private func updateAutoScroll(pointer: CGPoint) {
        guard autoScroller.pointerMoved(to: pointer, regions: scrollRegions) else {
            autoScrollTicker.stop()
            return
        }
        guard !autoScrollTicker.isRunning, let spaceAnchor else { return }
        autoScrollTicker.start(on: spaceAnchor) { [weak self] elapsed in
            self?.autoScrollTick(elapsed: elapsed)
        }
    }

    private func autoScrollTick(elapsed: Double) {
        guard machine.tracksMotion, let pointer = lastPointer else {
            stopAutoScroll()
            return
        }
        resolve(at: pointer)
        if let step = autoScroller.tick(pointer: pointer, regions: scrollRegions, elapsed: elapsed) {
            switch step.surface {
            case .strip: stripScroller?(step.offset)
            case .rail: railScroller?(step.offset)
            }
        }
        if !autoScroller.pointerMoved(to: pointer, regions: scrollRegions) {
            autoScrollTicker.stop()
        }
    }

    /// A reveal just changed what sits under the pointer; see
    /// `AutoScroller.springLoaded`.
    private func springLoadFired() {
        autoScrollTicker.stop()
        guard let lastPointer else { return }
        autoScroller.springLoaded(pointer: lastPointer, regions: scrollRegions)
    }

    private func stopAutoScroll() {
        autoScrollTicker.stop()
        autoScroller.reset()
        lastPointer = nil
    }

    // MARK: - Rail multi-selection

    /// True when the click is a plain one whose jump the caller should run.
    func clickWorkspace(_ id: WorkspaceID, commandHeld: Bool) -> Bool {
        updateSelection { $0.click(id, commandHeld: commandHeld) } == .jump(id)
    }

    func isWorkspaceMultiSelected(_ id: WorkspaceID) -> Bool {
        workspaceSelection.contains(id)
    }

    func workspaceDragSubject(pressing id: WorkspaceID) -> DragSubject {
        workspaceSelection.dragSubject(pressing: id, order: workspaceOrder)
    }

    private func finishWorkspaceSelection() {
        guard let activeSubject else { return }
        updateSelection { $0.dragFinished(activeSubject) }
    }

    /// Writes only a real change: rows observe the whole selection, and a
    /// keystroke that leaves it as it was must not re-render them.
    @discardableResult
    private func updateSelection<Result>(_ change: (inout WorkspaceSelection) -> Result) -> Result {
        var copy = workspaceSelection
        let result = change(&copy)
        if copy != workspaceSelection {
            workspaceSelection = copy
        }
        syncSelectionMonitor()
        return result
    }

    /// Present only while something is selected, so the rest of the time
    /// every press and key reaches its view untouched. Presses and other keys
    /// always pass through; only an Esc the selection takes is swallowed.
    private func syncSelectionMonitor() {
        guard !workspaceSelection.isEmpty else {
            if let selectionMonitor {
                NSEvent.removeMonitor(selectionMonitor)
            }
            selectionMonitor = nil
            if let selectionResignObserver {
                NotificationCenter.default.removeObserver(selectionResignObserver)
            }
            selectionResignObserver = nil
            return
        }
        if selectionMonitor == nil {
            selectionMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] event in
                self?.selectionSaw(event) ?? event
            }
        }
        if selectionResignObserver == nil {
            selectionResignObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateSelection { $0.disengage() } }
            }
        }
    }

    private func selectionSaw(_ event: NSEvent) -> NSEvent? {
        guard event.type == .keyDown else {
            let onRow = dragSpacePoint(event).map {
                WorkspaceSelection.isRailRow($0, rows: workspaceFrames.map(\.frame), viewport: railViewport)
            } ?? false
            updateSelection { $0.pointerPressed(onRailRow: onRow) }
            return event
        }
        guard Int(event.keyCode) == kVK_Escape else {
            updateSelection { $0.disengage() }
            return event
        }
        let dragIdle = machine.state == .idle
        return updateSelection { $0.escapePressed(dragIdle: dragIdle) } ? nil : event
    }

    private func dragSpacePoint(_ event: NSEvent) -> CGPoint? {
        guard let anchor = spaceAnchor, anchor.window === event.window else { return nil }
        let local = anchor.convert(event.locationInWindow, from: nil)
        return CGPoint(x: local.x, y: anchor.bounds.height - local.y)
    }

    // MARK: - What the overlays draw

    func isDragging(pane: PaneID) -> Bool { activeSubject == .pane(pane) }
    func isDragging(tab: TabID) -> Bool { activeSubject == .tab(tab) }
    func isDragging(workspace: WorkspaceID) -> Bool {
        switch activeSubject {
        case .workspace(let id)?: id == workspace
        case .workspaces(let ids)?: ids.contains(workspace)
        default: false
        }
    }

    var insertionMark: InsertionMark? {
        switch target {
        case .tabStrip(_, let insertIndex):
            guard let container = stripViewport ?? stripFrame else { return nil }
            let bar = InsertionBarGeometry.bar(
                atInsertIndex: insertIndex, items: tabFrames.map(\.frame), container: container, axis: .vertical
            )
            return InsertionMark(bar: bar, dot: InsertionBarGeometry.endDot(for: bar, axis: .vertical))
        case .workspaceRail(let insertIndex):
            guard let container = railViewport ?? railFrame else { return nil }
            let bar = InsertionBarGeometry.bar(
                atInsertIndex: insertIndex, items: workspaceFrames.map(\.frame), container: container, axis: .horizontal
            )
            return InsertionMark(bar: bar, dot: InsertionBarGeometry.endDot(for: bar, axis: .horizontal))
        default:
            return nil
        }
    }

    /// The outline over a whole-item target: a tab, a workspace row, or a
    /// new-tab/new-workspace zone. Canvas targets are not drawn here --
    /// `DropzoneOverlay` previews the whole post-drop layout for those.
    var targetHighlight: CGRect? {
        guard let target, let surfaces else { return nil }
        switch target {
        case .tabThumbnail, .workspaceThumbnail, .newTab, .newWorkspace:
            return dropTargetRect(for: target, surfaces: surfaces)
        case .paneEdge, .paneInterior, .tabStrip, .workspaceRail:
            return nil
        }
    }

    func tabDisplacement(at index: Int) -> CGFloat {
        guard case .tabStrip(_, let insertIndex)? = target else { return 0 }
        let items = tabFrames.map(\.frame)
        let draggingIndex = draggingTabIndex
        return ReshuffleOffset.displacement(
            forItemAt: index, draggingIndex: draggingIndex, insertIndex: insertIndex,
            extent: draggingIndex.map { ReshuffleOffset.advance(ofItemAt: $0, items: items, axis: .vertical) }
                ?? ReshuffleOffset.defaultExtent
        )
    }

    func workspaceDisplacement(at index: Int) -> CGFloat {
        guard case .workspaceRail(let insertIndex)? = target else { return 0 }
        let items = workspaceFrames.map(\.frame)
        if case .workspaces(let block)? = activeSubject {
            let members = Set(block)
            let blockIndices = Set(workspaceFrames.indices.filter { members.contains(workspaceFrames[$0].id) })
            return ReshuffleOffset.blockDisplacement(
                forItemAt: index, blockIndices: blockIndices, insertIndex: insertIndex, items: items, axis: .horizontal
            )
        }
        let draggingIndex = draggingWorkspaceIndex
        return ReshuffleOffset.displacement(
            forItemAt: index, draggingIndex: draggingIndex, insertIndex: insertIndex,
            extent: draggingIndex.map { ReshuffleOffset.advance(ofItemAt: $0, items: items, axis: .horizontal) }
                ?? ReshuffleOffset.defaultExtent
        )
    }

    private var draggingTabIndex: Int? {
        guard case .tab(let id)? = activeSubject else { return nil }
        return tabFrames.firstIndex { $0.id == id }
    }

    private var draggingWorkspaceIndex: Int? {
        guard case .workspace(let id)? = activeSubject else { return nil }
        return workspaceFrames.firstIndex { $0.id == id }
    }
}
