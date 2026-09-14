import Foundation
import Observation

/// The subset of `HerdrClient` the view-model needs to issue focus verbs and
/// pane reads. `HerdrClient` conforms below; a test double substitutes for
/// it in `SessionViewModelTests` without opening a real socket.
public protocol HerdrCommandClient: Sendable {
    func requestRaw(_ method: String, _ params: [String: JSONValue]) async throws -> Data
}

extension HerdrClient: HerdrCommandClient {}

public struct ProtocolMismatch: Equatable, Sendable {
    public let found: Int
    public let required: Int
}

/// Selection and focus-jump logic for the shell UI. Views render from this
/// (rail/strip/canvas) and stay untested until the e2e suite; every decision
/// about what is selected, and what herdr command a click issues, lives here.
@MainActor
@Observable
public final class SessionViewModel {
    public private(set) var model: SessionModel?
    public private(set) var connectionState: ConnectionState = .connecting
    public private(set) var selectedWorkspaceID: WorkspaceID?
    public private(set) var selectedTabID: TabID?
    public private(set) var optimisticFocusedPaneID: PaneID?
    public private(set) var lastLines: [PaneID: String] = [:]

    private var lastLineRevisions: [PaneID: Int] = [:]
    // One chained task per pane: every attach/mode/detach request for a pane
    // waits for whatever request came immediately before it (for that SAME
    // pane only -- other panes are unaffected) before touching
    // `ghosttySurfaces`. This is what actually closes the reentrancy hole a
    // simple "recheck after await" guard cannot: a resize arriving mid-attach,
    // or a mode switch arriving mid-detach, must never reach the surface
    // concurrently with whatever request is already in flight for the same
    // pane. Not pruned as requests settle -- bounded by how many distinct
    // panes have ever existed in the session, not by request volume, so this
    // does not grow unbounded in practice.
    private var paneWork: [PaneID: Task<Void, Never>] = [:]
    private let client: any HerdrCommandClient
    private let ghosttyFactory: (any GhosttyPaneFactory)?
    // Every visible pane's live surface, keyed by pane -- created exactly
    // once per pane, on first visibility, and torn down only when the pane
    // leaves the visible set entirely. Attach/mode/detach for a given pane
    // always goes through `paneWork`, so a focus flip can never race a
    // resize or a teardown for that pane.
    // `@ObservationIgnored`: `PaneCellView.init` reads this once (via
    // `ghosttySurface(for:)`) to seed its own `@State`, and that read runs
    // as part of `PaneCanvas.body` building its children -- without this,
    // EVERY mutation of this dict (any pane's attach, park, or teardown)
    // would invalidate the whole canvas's `body`, not just the one cell
    // that actually changed. Nothing in any view's `body` needs to react to
    // this dict changing after the fact; `@State`/`.task(id:)` already own
    // that reactivity per cell.
    @ObservationIgnored
    private var ghosttySurfaces: [PaneID: any GhosttyPaneSurface] = [:]
    /// Parked panes (detached from the visible set but kept warm), oldest
    /// park first -- the eviction order `evictWarmPanesIfNeeded` reads once
    /// the cap is exceeded. A pane leaves this list the moment it is
    /// attached again (warm reuse), so only panes that are STILL parked
    /// right now ever appear in it.
    private var parkedPanes: [PaneID] = []
    /// How many parked panes stay warm (a live surface, bridge and PTY each)
    /// before the oldest is torn down for real. A ceiling on the price of
    /// instant tab switching, not a cache that grows with the session --
    /// mirrors Herdglass's own `maxWarmPanes`.
    static let maxWarmPanes = 12
    /// The in-flight (or most recently settled) closed-pane teardown
    /// `Task`, so a test can await the exact settle point an `update(model:
    /// connection:)` call produces instead of polling. Production never
    /// reads this back.
    private var pendingClosedPaneTeardown: Task<Void, Never>?
    /// Every pane ID any `update(model:connection:)` snapshot has EVER
    /// reported, accumulated across calls. `reconcileClosedPanes` only ever
    /// tears a pane down as "closed" if it appears here -- i.e. herdr
    /// genuinely reported it at some point -- never merely because the
    /// current snapshot happens not to mention it. Production panes are
    /// always drawn from the model in the first place, so this is always a
    /// superset of anything attached in practice; it exists as a safety
    /// valve against attaching a pane the model never described at all.
    private var everKnownPaneIDs: Set<PaneID> = []
    // Which pane, if any, currently holds `.control` mode -- the ViewModel's
    // own record of what it last told a bridge, independent of
    // `resolvedFocusedPaneID` so a focus change can be diffed against it
    // (old pane gets `.observe`, new pane gets `.control`, in that order).
    private var modeArmedPane: PaneID?
    // The last mode actually sent to each pane's surface -- the dedup guard
    // `sendModeIfChanged` reads before every send, so two independently
    // triggered calls for the same pane (attach's own arm-check and a
    // reconcile that was enqueued before the pane had a surface at all, so
    // it could only find out once it finally ran) can never double-send the
    // identical mode. Cleared on detach: a fresh surface has told the
    // bridge nothing yet, whatever a previous surface for this pane once was.
    private var lastSentMode: [PaneID: PaneMode] = [:]
    // The in-flight (or most recently settled) mode-reconcile `Task`, so a
    // test can await the exact settle point a focus change produces without
    // polling -- `waitForPaneModeReconciliation()`. Production never reads
    // this back.
    private var pendingModeReconciliation: Task<Void, Never>?

    private let paneLauncherRegistry = PaneLauncherRegistry()

    // `nil` only when no `layoutExportClient` was injected (a test double
    // that only implements `HerdrCommandClient`, say); every pane canvas
    // then reads `exportedLayout(for:)` as `nil` and `CanvasGeometry.resolved`
    // falls back to rect derivation for every tab, same as a per-tab fetch
    // failure would.
    private let layoutExportCoordinator: LayoutExportCoordinator?

    // A `nil` `planExecutor` means no plan-execution seam exists at all:
    // `closePane` then falls back to a raw `pane.close` send, and `perform`
    // is a no-op (there is nothing it could route a plan to).
    private let planExecutor: (any PlanExecuting)?
    private let undoJournal: UndoJournal?
    private let noticeSink: @MainActor (String) -> Void

    public init(
        client: any HerdrCommandClient,
        ghosttyFactory: (any GhosttyPaneFactory)? = nil,
        layoutExportClient: (any LayoutExportClient)? = nil,
        planExecutor: (any PlanExecuting)? = nil,
        undoJournal: UndoJournal? = nil,
        noticeSink: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        self.client = client
        self.ghosttyFactory = ghosttyFactory
        self.layoutExportCoordinator = layoutExportClient.map { LayoutExportCoordinator(client: $0) }
        self.planExecutor = planExecutor
        self.undoJournal = undoJournal
        self.noticeSink = noticeSink
    }

    public var unsupportedBanner: ProtocolMismatch? {
        guard case .unsupported(let error) = connectionState,
              case .protocolTooOld(let found, let required) = error
        else { return nil }
        return ProtocolMismatch(found: found, required: required)
    }

    /// Called whenever `HerdrStore.model`/`connection` change. Workspace
    /// selection only ever fills in from `nil`. Tab selection now MIRRORS
    /// herdr's own focused tab live: a tab switch is a warm re-host (this
    /// task's whole point), cheap enough that paddock's view can just follow
    /// herdr's, the same way the rest of the session already does. Only an
    /// actual CHANGE of herdr's focused tab moves the selection -- comparing
    /// against the model's PREVIOUS `focusedTabID`, not against
    /// `selectedTabID` itself, is what lets a paddock-initiated selection
    /// that currently differs from herdr's last-known focus persist through
    /// an unrelated update (a `layoutUpdated` that touches neither) instead
    /// of being stomped back to whatever herdr already was focused on.
    public func update(model: SessionModel?, connection: ConnectionState) {
        let previousFocusedTabID = self.model?.focusedTabID
        self.model = model
        connectionState = connection
        if selectedWorkspaceID == nil {
            selectedWorkspaceID = model?.focusedWorkspaceID
        }
        if selectedTabID == nil {
            selectedTabID = model?.focusedTabID
        } else if let focusedTabID = model?.focusedTabID, focusedTabID != previousFocusedTabID {
            selectedTabID = focusedTabID
        }
        // The echo caught up: the model now agrees with what the click
        // predicted, so the prediction can stand down and let the model's
        // own field drive `resolvedFocusedPaneID` again.
        if optimisticFocusedPaneID != nil, model?.focusedPaneID == optimisticFocusedPaneID {
            optimisticFocusedPaneID = nil
        }
        refreshLayoutExports()
        reconcilePaneModeIfNeeded()
        reconcileClosedPanes()
    }

    /// Any pane herdr no longer reports (closed, or the model went nil) has
    /// nothing left to come back to, so its surface is torn down for real
    /// regardless of the warm cap -- keeping it parked would only leak a
    /// bridge and PTY nothing will ever reattach. Chained per-pane through
    /// `paneWork` like every other surface operation (`teardownSurface`),
    /// so this can never race an in-flight attach/park for the same pane.
    private func reconcileClosedPanes() {
        let known = Set((model?.panes ?? [:]).keys)
        everKnownPaneIDs.formUnion(known)
        let gone = ghosttySurfaces.keys.filter { everKnownPaneIDs.contains($0) && !known.contains($0) }
        guard !gone.isEmpty else {
            pendingClosedPaneTeardown = nil
            return
        }
        pendingClosedPaneTeardown = Task { [weak self] in
            guard let self else { return }
            for pane in gone {
                await self.teardownSurface(pane)
            }
        }
    }

    /// Lets a test await the exact closed-pane teardown a preceding
    /// `update(model:connection:)` call kicked off, instead of polling; a
    /// no-op (returns immediately) if none is pending. Production never
    /// calls this.
    public func waitForClosedPaneTeardown() async {
        await pendingClosedPaneTeardown?.value
    }

    /// Kicks the coordinator's per-tab refresh off the same seam every other
    /// derived state in this class updates from: `HerdrStore`'s own model
    /// stream, via `update(model:connection:)`. Selected tab first, the rest
    /// chained; each tab's `LayoutTopologySignature` is what keeps an
    /// unrelated tab's cached export from ever being refetched here.
    private func refreshLayoutExports() {
        guard let layoutExportCoordinator, let model else { return }
        layoutExportCoordinator.refresh(
            tabIDsInOrder: model.layouts.keys.sorted { $0.rawValue < $1.rawValue },
            layouts: model.layouts,
            selectedTabID: selectedTabID
        )
    }

    /// The split tree the coordinator has cached for `tabID`, or `nil` before
    /// its first successful `layout.export` (or while that tab is in
    /// fallback). `PaneCanvas` reads this to drive `CanvasGeometry.resolved`.
    public func exportedLayout(for tabID: TabID) -> ExportedLayoutDescription? {
        layoutExportCoordinator?.exportedLayouts[tabID]
    }

    /// Lets a test await the coordinator's in-flight refresh instead of
    /// racing it; a no-op when no `layoutExportClient` was injected.
    public func waitForLayoutExportsIdle() async {
        await layoutExportCoordinator?.waitForIdle()
    }

    /// What views should treat as "the focused pane": the optimistic click
    /// target while a `pane.focus` round trip is in flight (or has not yet
    /// echoed back), else the model's own field. Painting from this instead
    /// of `model?.focusedPaneID` directly is what makes the accent ring move
    /// on the same frame as the click rather than 24-100+ms later. The same
    /// field drives which pane's bridge holds `.control` mode -- see
    /// `reconcilePaneModeIfNeeded`.
    public var resolvedFocusedPaneID: PaneID? {
        optimisticFocusedPaneID ?? model?.focusedPaneID
    }

    /// The selected workspace's tabs, or `[]` when nothing is selected yet
    /// or the workspace has none.
    public var tabsForSelectedWorkspace: [TabRecord] {
        guard let workspaceID = selectedWorkspaceID else { return [] }
        return model?.tabs[workspaceID] ?? []
    }

    /// The layout snapshot for the selected tab, or `nil` when no tab is
    /// selected or the model has no layout for it yet.
    public var selectedLayout: LayoutSnapshot? {
        guard let tabID = selectedTabID else { return nil }
        return model?.layouts[tabID]
    }

    /// Count of panes belonging to `workspaceID`, `0` when it has none.
    public func paneCount(for workspaceID: WorkspaceID) -> Int {
        model?.panes.values.filter { $0.workspaceID == workspaceID }.count ?? 0
    }

    public func select(workspace id: WorkspaceID) {
        selectedWorkspaceID = id
        selectedTabID = model?.workspaces.first { $0.workspaceID == id }?.activeTabID
    }

    public func select(tab id: TabID) {
        selectedTabID = id
    }

    public func jumpToHerdr(workspace id: WorkspaceID) async {
        select(workspace: id)
        await send("workspace.focus", ["workspace_id": .string(id.rawValue)])
    }

    public func jumpToHerdr(tab id: TabID) async {
        select(tab: id)
        await send("tab.focus", ["tab_id": .string(id.rawValue)])
    }

    /// Sets the optimistic prediction synchronously, before the request even
    /// goes out, so the ring paints on the same frame as the click. A second
    /// click before this one's echo lands simply overwrites the prediction
    /// (last click wins); if THIS request throws, the prediction reverts to
    /// the model's truth -- but only if a later click hasn't already
    /// superseded it (the `== id` guard).
    public func jumpToHerdr(pane id: PaneID) async {
        optimisticFocusedPaneID = id
        reconcilePaneModeIfNeeded()
        do {
            _ = try await client.requestRaw("pane.focus", ["pane_id": .string(id.rawValue)])
        } catch {
            if optimisticFocusedPaneID == id {
                optimisticFocusedPaneID = nil
                reconcilePaneModeIfNeeded()
            }
        }
    }

    /// Returns the cached last line for a status-card pane, kicking off a
    /// fetch when the cache is missing or stale for the pane's current
    /// `revision`. Callers (status-card views) call this every render; the
    /// revision check keeps it a no-op once the fetch for that revision lands.
    public func lastLine(for pane: PaneRecord) -> String? {
        ensureLastLineLoaded(for: pane)
        return lastLines[pane.paneID]
    }

    private func ensureLastLineLoaded(for pane: PaneRecord) {
        if lastLineRevisions[pane.paneID] == pane.revision { return }
        lastLineRevisions[pane.paneID] = pane.revision
        let paneID = pane.paneID
        Task { @MainActor [weak self] in
            guard let self else { return }
            let params: [String: JSONValue] = [
                "pane_id": .string(paneID.rawValue),
                "source": .string("visible"),
                "lines": .int(1),
            ]
            guard let data = try? await self.client.requestRaw("pane.read", params),
                  let line = Self.extractLastLine(data)
            else { return }
            self.lastLines[paneID] = line
        }
    }

    private static func extractLastLine(_ data: Data) -> String? {
        struct Result: Decodable { let text: String }
        struct Envelope: Decodable { let result: Result }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { return nil }
        let trimmed = envelope.result.text.trimmingCharacters(in: .newlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.split(separator: "\n").last.map(String.init) ?? trimmed
    }

    private func send(_ method: String, _ params: [String: JSONValue]) async {
        _ = try? await client.requestRaw(method, params)
    }

    // MARK: - ghostty pane attach (every visible pane, one surface for its whole life; parked when not visible)

    /// Creates `pane`'s ghostty surface the first time, unparks and resizes
    /// a warm (previously parked) one, or just resizes an already-visible
    /// one -- never a second surface for a pane that already has one, warm
    /// or not. Chained through `paneWork` (see its own doc comment), so a
    /// resize racing a fresh attach for the same pane can never reach the
    /// factory concurrently. Returns the surface (new, warm, or already
    /// visible) so a caller can hand it to `@State`, reading `ghosttySurface
    /// (for:)` back out independently would depend on whether a dictionary
    /// mutation buried inside a method call still registers as an
    /// `@Observable` access, which this sidesteps entirely.
    @discardableResult
    public func attachPane(_ pane: PaneID, cols: Int, rows: Int) async -> (any GhosttyPaneSurface)? {
        guard let ghosttyFactory, cols > 0, rows > 0 else { return nil }
        parkedPanes.removeAll { $0 == pane }
        let previous = paneWork[pane]
        let task = Task { [weak self] in
            _ = await previous?.value
            guard let self else { return }
            await self.performAttach(pane: pane, cols: cols, rows: rows, factory: ghosttyFactory)
        }
        paneWork[pane] = task
        await task.value
        return ghosttySurfaces[pane]
    }

    /// PARKS `pane`'s ghostty surface -- called when the pane leaves the
    /// visible set (tab switch, split closed, window resize dropping it off
    /// screen). The surface itself is kept alive, its bridge dropped to
    /// observe mode (still receiving frames), and marked occluded so
    /// libghostty stops drawing a pane nothing can see; `attachPane` reuses
    /// it, unparked, the moment the pane is visible again -- no flash, no
    /// fresh bridge/PTY. Only the warm cap's own eviction, or herdr no
    /// longer reporting this pane at all, tears a surface down for real (see
    /// `evictWarmPanesIfNeeded`, `reconcileClosedPanes`). Chained through
    /// `paneWork` like `attachPane`.
    public func detachPane(_ pane: PaneID) async {
        let previous = paneWork[pane]
        let task = Task { [weak self] in
            _ = await previous?.value
            await self?.performPark(pane: pane)
        }
        paneWork[pane] = task
        await task.value
        if modeArmedPane == pane {
            modeArmedPane = nil
        }
    }

    /// `pane`'s live ghostty surface, if it has one -- warm (parked) or
    /// visible. `PaneCellView` reads this at `init` to seed its `@State`
    /// synchronously, so a warm pane never renders the status card even for
    /// one frame.
    public func ghosttySurface(for pane: PaneID) -> (any GhosttyPaneSurface)? {
        ghosttySurfaces[pane]
    }

    private func performAttach(pane: PaneID, cols: Int, rows: Int, factory: any GhosttyPaneFactory) async {
        // also removed here, inside the chain -- `attachPane`'s own
        // synchronous removal (before this step even runs) closes the
        // common case, but a park enqueued for the SAME pane can still be
        // the step that actually appends to `parkedPanes`, and it may not
        // run until AFTER that synchronous removal already happened (both
        // `detachPane`/`performPark` and this attach share `paneWork[pane]`,
        // but the sync removal in `attachPane` is not itself part of that
        // chain). Removing again here, on the chain, is what actually closes
        // the race: whichever of park/attach for this pane runs LAST always
        // leaves `parkedPanes` agreeing with reality.
        parkedPanes.removeAll { $0 == pane }
        if let existing = ghosttySurfaces[pane] {
            existing.unpark()
            existing.resize(cols: cols, rows: rows)
            // a warm reattach needs arming exactly like a cold one --
            // the pane could easily be the resolved-focused one already (the
            // tab it belongs to is being switched back TO because it holds
            // focus), and without this it would sit warm in observe mode
            // until the next unrelated focus flip happened to reconcile it.
            if resolvedFocusedPaneID == pane {
                await sendModeIfChanged(.control, to: pane, surface: existing)
                modeArmedPane = pane
            }
            return
        }
        // Both closures are the launcher-pristine contract's ghostty half:
        // see `GhosttyPaneFactory.makeSurface`'s doc comment. The screen-
        // activity one guards on `isPristineLauncherPane` itself before
        // ever touching the registry -- once ANY path (a keystroke, or this
        // one) has hidden the pane, every later call is a cheap no-op that
        // also tells the surface to stop reporting for good.
        let surface = await factory.makeSurface(
            for: pane, cols: cols, rows: rows,
            onUserInput: { [weak self] in self?.recordLauncherKeystroke(pane) },
            onScreenActivity: { [weak self] nonEmptyRowCount in
                guard let self, self.isPristineLauncherPane(pane) else { return false }
                self.recordLauncherScreenActivity(pane, nonEmptyRowCount: nonEmptyRowCount)
                return self.isPristineLauncherPane(pane)
            }
        )
        ghosttySurfaces[pane] = surface
        // A bridge is always born in observe mode (`ControlBridge.run`); only
        // the currently resolved-focused pane needs telling to switch --
        // every other pane simply stays at its default. Read the CURRENT
        // resolved focus, never a caller-supplied flag, so a focus change
        // that lands mid-attach is never missed.
        if resolvedFocusedPaneID == pane {
            await sendModeIfChanged(.control, to: pane, surface: surface)
            modeArmedPane = pane
        }
    }

    /// Drops `pane`'s bridge to observe mode -- but only if it was actually
    /// in control mode; a pane that was never focused (or was already
    /// explicitly set to observe) gets no redundant real send, since the
    /// bridge already defaults to observe on its own. Marks its surface
    /// occluded and moves it to the back of the warm queue -- never removed
    /// from `ghosttySurfaces`, which is the whole difference between this
    /// and `performTeardown`. Evicts the warm cap's overflow afterward,
    /// oldest park first.
    private func performPark(pane: PaneID) async {
        guard let surface = ghosttySurfaces[pane] else { return }
        if lastSentMode[pane] == .control {
            await sendModeIfChanged(.observe, to: pane, surface: surface)
        }
        surface.park()
        parkedPanes.removeAll { $0 == pane }
        parkedPanes.append(pane)
        await evictWarmPanesIfNeeded()
    }

    /// Tears down whichever parked panes now exceed `maxWarmPanes`, oldest
    /// park first -- each through `teardownSurface`, so an eviction can
    /// never race an attach/park already in flight for that SAME pane.
    private func evictWarmPanesIfNeeded() async {
        guard parkedPanes.count > Self.maxWarmPanes else { return }
        let overflow = parkedPanes.count - Self.maxWarmPanes
        let stale = Array(parkedPanes.prefix(overflow))
        parkedPanes.removeFirst(overflow)
        for pane in stale {
            await teardownSurface(pane)
        }
    }

    /// Tears `pane`'s surface down for real: the warm cap's own eviction, or
    /// herdr no longer reporting this pane at all (`reconcileClosedPanes`).
    /// Chained through `paneWork` like every other per-pane operation.
    private func teardownSurface(_ pane: PaneID) async {
        let previous = paneWork[pane]
        let task = Task { [weak self] in
            _ = await previous?.value
            await self?.performTeardown(pane: pane)
        }
        paneWork[pane] = task
        await task.value
    }

    private func performTeardown(pane: PaneID) async {
        guard let surface = ghosttySurfaces.removeValue(forKey: pane) else { return }
        lastSentMode.removeValue(forKey: pane)
        parkedPanes.removeAll { $0 == pane }
        if modeArmedPane == pane {
            modeArmedPane = nil
        }
        await surface.detach()
    }

    // MARK: - mode switch (focus-driven, at most one control-mode pane)

    /// Diffs `resolvedFocusedPaneID` against `modeArmedPane` and, if they
    /// differ, sends `.observe` to whichever pane was armed before sending
    /// `.control` to whichever pane is armed now -- in that order, awaited
    /// sequentially, so a bridge is never asked to hold `.control` while the
    /// pane that is about to replace it still does. `modeArmedPane` itself
    /// updates synchronously (before either send goes out) so a second,
    /// faster flip arriving while the first is still in flight diffs
    /// against the NEWEST target, not a stale one.
    private func reconcilePaneModeIfNeeded() {
        let resolved = resolvedFocusedPaneID
        guard resolved != modeArmedPane else { return }
        let old = modeArmedPane
        modeArmedPane = resolved
        pendingModeReconciliation = Task { [weak self] in
            guard let self else { return }
            if let old { await self.applyCurrentlyArmedMode(for: old) }
            if let resolved { await self.applyCurrentlyArmedMode(for: resolved) }
        }
    }

    /// Sets `pane`'s surface to whichever mode `modeArmedPane` says is
    /// correct AT THE MOMENT this step actually runs on `pane`'s own
    /// `paneWork` chain -- never a mode value captured when the reconcile
    /// `Task` above was created. This is what keeps a fast A -> B -> A focus
    /// flip-flop correct: `reconcilePaneModeIfNeeded` fires one such `Task`
    /// per transition, and two of them can touch the SAME pane's chain in
    /// either order (their own two steps chase different panes, so they
    /// never serialize against each other directly) -- a captured `.control`
    /// for a pane that was only briefly the target can otherwise apply
    /// AFTER a later transition already demoted it, leaving two panes
    /// armed. Deriving `desired` fresh, from `modeArmedPane`, every time a
    /// step for this pane finally runs closes that: whichever step for a
    /// given pane runs LAST always re-reads the live intent and corrects
    /// course if a stale one already applied the wrong mode.
    private func applyCurrentlyArmedMode(for pane: PaneID) async {
        let previous = paneWork[pane]
        let task = Task { [weak self] in
            _ = await previous?.value
            guard let self, let surface = self.ghosttySurfaces[pane] else { return }
            let desired: PaneMode = (self.modeArmedPane == pane) ? .control : .observe
            await self.sendModeIfChanged(desired, to: pane, surface: surface)
        }
        paneWork[pane] = task
        await task.value
    }

    /// Lets a test await the exact focus-driven mode-reconcile step a
    /// preceding `update`/`jumpToHerdr(pane:)` call kicked off, instead of
    /// polling; a no-op (returns immediately) if no reconciliation is
    /// pending. Production never calls this.
    public func waitForPaneModeReconciliation() async {
        await pendingModeReconciliation?.value
    }

    /// Sends `mode` to `pane`'s surface, chained through `paneWork` like
    /// every other per-pane request: a call queued behind an in-flight
    /// attach/detach/mode-switch for the SAME pane waits for it to settle
    /// first, and -- since `paneWork[pane]` always holds only the LAST
    /// enqueued step -- a stale call whose own step is still running when a
    /// fresher one for the same pane is issued can never have its (delayed)
    /// effect land after the fresher one and clobber it: the fresher step
    /// simply becomes the new chain tail, and whichever step actually runs
    /// last decides the pane's settled mode. A pane with no surface yet
    /// (detached, or never attached) is a no-op; `attachPane` arms a
    /// freshly-created surface itself, from the resolved focus at that
    /// moment, so this method never needs to.
    @discardableResult
    public func setPaneMode(_ mode: PaneMode, for pane: PaneID) async -> Bool {
        let previous = paneWork[pane]
        let task = Task { [weak self] in
            _ = await previous?.value
            guard let self, let surface = self.ghosttySurfaces[pane] else { return }
            await self.sendModeIfChanged(mode, to: pane, surface: surface)
        }
        paneWork[pane] = task
        await task.value
        return ghosttySurfaces[pane] != nil
    }

    /// The single writer of every mode a pane's surface is ever told --
    /// `performAttach`'s own arm-on-attach and `setPaneMode`'s
    /// reconcile-driven calls both go through this, so the two can never
    /// double-apply the identical mode to the same pane just because a
    /// reconcile enqueued BEFORE a pane's surface existed happens to run
    /// AFTER `attachPane` already armed it (the reconcile Task and
    /// `attachPane`'s own task are independently scheduled; `paneWork`
    /// orders them relative to each OTHER but neither knows what mode the
    /// other already sent). Comparing against `lastSentMode` -- not against
    /// how the call was triggered -- is what makes a redundant send
    /// impossible regardless of interleaving.
    private func sendModeIfChanged(_ mode: PaneMode, to pane: PaneID, surface: any GhosttyPaneSurface) async {
        guard lastSentMode[pane] != mode else { return }
        lastSentMode[pane] = mode
        await surface.setMode(mode)
    }

    // MARK: - new-pane harness launcher

    /// `PaneLauncherRegistry` is a plain (non-`@Observable`) class, so a
    /// mutation to it alone would never invalidate a SwiftUI view reading
    /// `isPristineLauncherPane`. This counter is the observation seam: every
    /// mutating call below bumps it, and `isPristineLauncherPane` reads it
    /// (result discarded) purely to register that dependency.
    public private(set) var launcherRegistryVersion = 0

    public func isPristineLauncherPane(_ pane: PaneID) -> Bool {
        _ = launcherRegistryVersion
        return paneLauncherRegistry.isPristine(pane)
    }

    public func recordLauncherKeystroke(_ pane: PaneID) {
        paneLauncherRegistry.recordKeystroke(pane)
        launcherRegistryVersion += 1
    }

    /// The launcher-pristine contract's screen-activity half: a pane whose
    /// program prints real output, never typed into, also hides the
    /// overlay. `nonEmptyRowCount` is the surface's own retained-screen
    /// count (`GhosttySession.reportScreenActivityIfDue`); the threshold
    /// for "still just the bare prompt" lives in `PaneLauncherRegistry`.
    public func recordLauncherScreenActivity(_ pane: PaneID, nonEmptyRowCount: Int) {
        paneLauncherRegistry.recordScreenActivity(pane, nonEmptyRowCount: nonEmptyRowCount)
        launcherRegistryVersion += 1
    }

    /// Sends `<binary>\n` to `pane` in one `send_input` call (the overlay's
    /// click contract) and hides the launcher for that pane immediately,
    /// same as a real keystroke would.
    public func launchHarness(_ binary: String, in pane: PaneID) async {
        _ = try? await client.requestRaw(
            "pane.send_input", ["pane_id": .string(pane.rawValue), "text": .string(binary + "\n")]
        )
        recordLauncherKeystroke(pane)
    }

    /// Splits `pane` rightward via `pane.split` and focuses the new pane,
    /// registering it as paddock-created so the launcher can show on it --
    /// a "Split Right" context-menu command exercising the provenance
    /// registry live; `cwd` is deliberately omitted so herdr follows the
    /// source pane's own cwd.
    public func splitRight(from pane: PaneID) async {
        await performSplit(from: pane, direction: "right")
    }

    /// Same shape as `splitRight`, `direction: "down"` per herdr's
    /// `SplitDirection` schema (only `right`/`down` exist; there is no
    /// `up`/`left`).
    public func splitDown(from pane: PaneID) async {
        await performSplit(from: pane, direction: "down")
    }

    private func performSplit(from pane: PaneID, direction: String) async {
        guard let data = try? await client.requestRaw(
            "pane.split",
            ["target_pane_id": .string(pane.rawValue), "direction": .string(direction), "focus": .bool(true)]
        ) else { return }
        guard let newPaneID = Self.extractSplitPaneID(data) else { return }
        paneLauncherRegistry.registerPaddockCreated(newPaneID)
        launcherRegistryVersion += 1
    }

    /// Closes `pane`. Routed through `planExecutor` as a single-op `OpPlan`
    /// when one is injected, so the close still lands in the undo journal --
    /// its inverse is empty and `ExecutedPlan.irreversible` names the close,
    /// so undoing it surfaces "nothing to undo for a close" rather than
    /// silently doing nothing. Falls back to a raw `pane.close` send when no
    /// executor was injected (test doubles that only supply a bare client).
    /// When an `undoJournal` is also injected, this runs through its shared
    /// chain (see `UndoJournal.runExclusively`) so it can never interleave
    /// with an in-flight `perform`/`undo`/`redo`.
    public func closePane(_ pane: PaneID) async {
        guard let planExecutor else {
            _ = try? await client.requestRaw("pane.close", ["pane_id": .string(pane.rawValue)])
            return
        }
        guard let undoJournal else {
            await Self.closePane(pane, executor: planExecutor, notify: noticeSink) { _ in }
            return
        }
        await undoJournal.runExclusively { [noticeSink] in
            await Self.closePane(pane, executor: planExecutor, notify: noticeSink, record: undoJournal.record)
        }
    }

    private static func closePane(
        _ pane: PaneID, executor: any PlanExecuting, notify: @MainActor (String) -> Void, record: @MainActor (ExecutedPlan) -> Void
    ) async {
        let result = await executor.execute(OpPlan(ops: [.closePane(pane)], label: "Close pane"))
        switch result {
        case .success(let executed):
            record(executed)
        case .failure(let failure):
            notify("Close pane failed: \(failure.message)")
        }
    }

    /// Runs one context-menu move/swap command: plans `subject` onto
    /// `target` against the live model, executes the resulting plan through
    /// `planExecutor`, and records the outcome in `undoJournal`. `.noOp`
    /// (e.g. a pane dropped onto its own tab) is silently ignored -- the
    /// menu already excludes the pane's own tab, so this is a defensive
    /// no-op rather than a path real menu selections take. When an
    /// `undoJournal` is injected, this runs through its shared chain so it
    /// can never interleave with an in-flight `undo`/`redo` (a `record` call
    /// racing an in-flight `undo`'s own stack mutation would otherwise be
    /// able to wipe the redo stack mid-step).
    public func perform(subject: DragSubject, target: DropTarget) async {
        guard planExecutor != nil else { return }
        guard let undoJournal else {
            guard let model, let planExecutor else { return }
            await Self.perform(subject: subject, target: target, model: model, executor: planExecutor, notify: noticeSink) { _ in }
            return
        }
        // Reads `model` fresh once this closure actually runs, not at the
        // moment `perform` was called: queued behind an in-flight
        // undo/redo, the model can move on while this waits its turn, and
        // planning against a snapshot captured before the wait would plan
        // against a tab/workspace arrangement that no longer holds.
        await undoJournal.runExclusively { [weak self] in
            guard let self, let model = self.model, let planExecutor = self.planExecutor else { return }
            await Self.perform(subject: subject, target: target, model: model, executor: planExecutor, notify: self.noticeSink, record: undoJournal.record)
        }
    }

    private static func perform(
        subject: DragSubject, target: DropTarget, model: SessionModel,
        executor: any PlanExecuting, notify: @MainActor (String) -> Void, record: @MainActor (ExecutedPlan) -> Void
    ) async {
        switch plan(dragging: subject, onto: target, model: model) {
        case .failure(.noOp):
            return
        case .failure(.invalidCombination):
            notify("Can't move there")
        case .success(let opPlan):
            let result = await executor.execute(opPlan)
            switch result {
            case .success(let executed):
                record(executed)
            case .failure(let failure):
                notify("\(opPlan.label) failed: \(failure.message)")
            }
        }
    }

    /// `pane.split`'s response nests the new pane's id under a `"pane"` key
    /// (verified against herdr's `PaneSplitResult` and pinned by
    /// `spikes/lib/seed-layout.sh`'s own `.result.pane.pane_id` read).
    private static func extractSplitPaneID(_ data: Data) -> PaneID? {
        struct PanePayload: Decodable {
            let paneID: PaneID
            enum CodingKeys: String, CodingKey { case paneID = "pane_id" }
        }
        struct Result: Decodable { let pane: PanePayload }
        struct Envelope: Decodable { let result: Result }
        return try? JSONDecoder().decode(Envelope.self, from: data).result.pane.paneID
    }
}
