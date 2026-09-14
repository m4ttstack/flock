import AppKit
import Carbon.HIToolbox
import Observation
import PaddockCore
import SwiftUI

/// What the commit seam last returned, so the visual layer can tell a real
/// landing from a plan that was legitimately a no-op: both leave
/// `DragController.phase` at `.idle`, and only one of them earns a flash.
@MainActor
final class DragOutcomeRelay {
    var last: DragOutcome?
}

/// The one place the drag gestures, the live layout, and `DragController`
/// meet: gestures report points in the drag space, the surfaces they hit-test
/// against are assembled from the frames each view publishes, and everything
/// the overlays draw is derived here rather than in a SwiftUI body.
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
    /// The subject for as long as its ghost is on screen, settle included --
    /// `controller.phase` is already back to `.idle` while the spring runs,
    /// and the origin must stay faded until the ghost is gone.
    private(set) var activeSubject: DragSubject?
    /// Non-nil only while the settle spring runs; the ghost is drawn here
    /// instead of at the cursor, and the spring is what carries it there.
    private(set) var settleTopLeft: CGPoint?
    private(set) var landingFlash: LandingFlash?

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
    /// going stale behind them.
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

    /// Frames arrive one item at a time as each row lays out, so the strip and
    /// the rail publish their ORDER separately; that order is what turns the
    /// frames back into a list, and it is also what drops an item's stale
    /// frame once the item itself is gone.
    private(set) var tabOrder: [TabID] = []
    private(set) var workspaceOrder: [WorkspaceID] = []
    private var tabFrameByID: [TabID: CGRect] = [:]
    private var workspaceFrameByID: [WorkspaceID: CGRect] = [:]

    @ObservationIgnored private let toasts: ToastCenter
    @ObservationIgnored private let rearrangeMode: RearrangeMode
    @ObservationIgnored private let outcomes = DragOutcomeRelay()
    /// Where the gesture started, for the cancel spring-back.
    @ObservationIgnored private var grabPoint: CGPoint = .zero
    /// Read from `deinit`, which runs outside actor isolation for a
    /// `@MainActor` class -- the same pattern `RearrangeMode` uses for its own
    /// event monitor.
    @ObservationIgnored nonisolated(unsafe) private var keyMonitor: Any?
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
        controller = DragController(
            commit: { subject, target in
                let outcome = await commit(subject, target)
                outcomes.last = outcome
                return outcome
            },
            springLoadAction: springLoadAction
        )
    }

    deinit {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
    }

    // MARK: - Surface registration

    var tabFrames: [TabItemFrame] {
        tabOrder.compactMap { id in tabFrameByID[id].map { TabItemFrame(id: id, frame: $0) } }
    }

    var workspaceFrames: [WorkspaceItemFrame] {
        workspaceOrder.compactMap { id in workspaceFrameByID[id].map { WorkspaceItemFrame(id: id, frame: $0) } }
    }

    func setTabOrder(_ order: [TabID]) {
        guard tabOrder != order else { return }
        tabOrder = order
    }

    func setWorkspaceOrder(_ order: [WorkspaceID]) {
        guard workspaceOrder != order else { return }
        workspaceOrder = order
    }

    func setTabFrame(_ frame: CGRect, for id: TabID) {
        guard tabFrameByID[id] != frame else { return }
        tabFrameByID[id] = frame
    }

    func setWorkspaceFrame(_ frame: CGRect, for id: WorkspaceID) {
        guard workspaceFrameByID[id] != frame else { return }
        workspaceFrameByID[id] = frame
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
            newTabZone: newTabZone,
            newWorkspaceZone: newWorkspaceZone
        )
    }

    // MARK: - Gesture lifecycle

    func begin(_ subject: DragSubject, ghost: Ghost, at point: CGPoint) {
        settleTask?.cancel()
        settleTopLeft = nil
        grabPoint = point
        activeSubject = subject
        self.ghost = ghost
        controller.began(subject, at: point)
        // Rearrange mode holds itself open for the length of the drag, so
        // releasing Control mid-drag does not repaint the panes out from
        // under the gesture.
        rearrangeMode.dragBegan()
        installKeyMonitor()
    }

    func move(to point: CGPoint) {
        guard let surfaces else { return }
        controller.moved(to: point, surfaces: surfaces)
    }

    func end() {
        removeKeyMonitor()
        rearrangeMode.dragEnded()
        guard case .dragging(_, _, let target) = controller.phase else {
            settle(to: DragVisuals.ghostTopLeft(forCursor: grabPoint))
            return
        }
        let landing = target.flatMap { resolved in surfaces.flatMap { dropTargetRect(for: resolved, surfaces: $0) } }
        outcomes.last = nil
        Task { [weak self] in
            await self?.controller.ended()
            self?.finish(landing: landing)
        }
    }

    func cancel() {
        removeKeyMonitor()
        rearrangeMode.dragEnded()
        controller.cancelled()
        settle(to: DragVisuals.ghostTopLeft(forCursor: grabPoint))
    }

    /// Settles the phase back to rest and sends the ghost where the outcome
    /// says it belongs: into the landing zone it actually reached, or home.
    private func finish(landing: CGRect?) {
        if case .rejected(let reason) = controller.phase {
            report(reason)
            // The only public way back to `.idle` from `.rejected`, and it
            // issues no commit of its own.
            controller.cancelled()
            settle(to: DragVisuals.ghostTopLeft(forCursor: grabPoint))
            return
        }
        guard outcomes.last == .committed, let landing else {
            settle(to: DragVisuals.ghostTopLeft(forCursor: grabPoint))
            return
        }
        flash(landing)
        settle(to: landing.origin)
    }

    private func settle(to topLeft: CGPoint) {
        settleTopLeft = topLeft
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
        settleTopLeft = nil
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

    // MARK: - Esc and Space, for the length of the drag only

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
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
        }
    }

    private func removeKeyMonitor() {
        guard let keyMonitor else { return }
        NSEvent.removeMonitor(keyMonitor)
        self.keyMonitor = nil
    }

    // MARK: - What the overlays draw

    var target: DropTarget? {
        guard case .dragging(_, _, let target) = controller.phase else { return nil }
        return target
    }

    func isDragging(pane: PaneID) -> Bool { activeSubject == .pane(pane) }
    func isDragging(tab: TabID) -> Bool { activeSubject == .tab(tab) }
    func isDragging(workspace: WorkspaceID) -> Bool { activeSubject == .workspace(workspace) }

    var isSettling: Bool { settleTopLeft != nil }

    var ghostTopLeft: CGPoint? {
        if let settleTopLeft { return settleTopLeft }
        guard case .dragging(_, let point, _) = controller.phase else { return nil }
        return DragVisuals.ghostTopLeft(forCursor: point)
    }

    var insertionMark: InsertionMark? {
        switch target {
        case .tabStrip(_, let insertIndex):
            guard let stripFrame else { return nil }
            let bar = InsertionBarGeometry.bar(
                atInsertIndex: insertIndex, items: tabFrames.map(\.frame), container: stripFrame, axis: .vertical
            )
            return InsertionMark(bar: bar, dot: InsertionBarGeometry.endDot(for: bar, axis: .vertical))
        case .workspaceRail(let insertIndex):
            guard let railFrame else { return nil }
            let bar = InsertionBarGeometry.bar(
                atInsertIndex: insertIndex, items: workspaceFrames.map(\.frame), container: railFrame, axis: .horizontal
            )
            return InsertionMark(bar: bar, dot: InsertionBarGeometry.endDot(for: bar, axis: .horizontal))
        default:
            return nil
        }
    }

    /// The outline over a whole-item target: a tab pill, a workspace row, or a
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
