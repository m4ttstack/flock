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

    /// Written from inside view bodies, which must not invalidate the views
    /// reading it; `lastLines` is what they observe.
    @ObservationIgnored private var lastLineRequests = LastLineRequests()
    // One chained task per pane: every attach/park/teardown request for a
    // pane waits for whatever request came immediately before it (for that
    // SAME pane only; other panes are unaffected) before touching
    // `ghosttySurfaces`. This is what actually closes the reentrancy hole a
    // simple "recheck after await" guard cannot: a second attach or a
    // teardown arriving mid-attach must never reach the surface concurrently
    // with whatever request is already in flight for the same pane. Not
    // pruned as requests settle: bounded by how many distinct panes have ever
    // existed in the session, not by request volume, so this does not grow
    // unbounded in practice.
    private var paneWork: [PaneID: Task<Void, Never>] = [:]
    private let client: any HerdrCommandClient
    private let ghosttyFactory: (any GhosttyPaneFactory)?
    // Every visible pane's live surface, keyed by pane -- created exactly
    // once per pane, on first visibility, and torn down only when the pane
    // leaves the visible set entirely. Attach/park/teardown for a given pane
    // always goes through `paneWork`.
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

    private let paneLauncherRegistry = PaneLauncherRegistry()
    // Armed per visible pane on attach, disarmed on park and teardown, so a
    // pane's scroll feed lives exactly as long as something can show it.
    // `nil` when nothing was injected (a bare test double); the indicator
    // then only ever sees the snapshot's own scroll state.
    private let paneScrollSubscriber: (any PaneScrollSubscribing)?

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
        paneScrollSubscriber: (any PaneScrollSubscribing)? = nil,
        noticeSink: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        self.client = client
        self.ghosttyFactory = ghosttyFactory
        self.layoutExportCoordinator = layoutExportClient.map { LayoutExportCoordinator(client: $0) }
        self.planExecutor = planExecutor
        self.undoJournal = undoJournal
        self.paneScrollSubscriber = paneScrollSubscriber
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
    /// of being stomped back to whatever herdr already was focused on. A
    /// followed tab brings its workspace along (`select(tab:)`): herdr's
    /// focus can land in another workspace, a pane followed after a drop
    /// into another workspace's tab, and a window showing that tab under the
    /// old workspace's rail and strip would show two workspaces at once.
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
            select(tab: focusedTabID)
        }
        // The echo caught up: the model now agrees with what the click
        // predicted, so the prediction can stand down and let the model's
        // own field drive `resolvedFocusedPaneID` again.
        if optimisticFocusedPaneID != nil, model?.focusedPaneID == optimisticFocusedPaneID {
            optimisticFocusedPaneID = nil
        }
        refreshLayoutExports()
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
    /// field decides which pane's surface accepts input, mouse and wheel
    /// (`InputSinkDisposition`, `MouseForwarding`).
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

    /// A tab can belong to a workspace other than the selected one (a grid
    /// thumbnail), and the strip shows only the selected workspace's tabs, so
    /// its workspace is selected along with it.
    public func select(tab id: TabID) {
        if let owner = model?.tabs.first(where: { $0.value.contains { $0.tabID == id } })?.key, owner != selectedWorkspaceID {
            selectedWorkspaceID = owner
        }
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
        do {
            _ = try await client.requestRaw("pane.focus", ["pane_id": .string(id.rawValue)])
        } catch {
            if optimisticFocusedPaneID == id {
                optimisticFocusedPaneID = nil
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
        guard lastLineRequests.begin(pane: pane.paneID, revision: pane.revision) else { return }
        let paneID = pane.paneID
        let revision = pane.revision
        Task { @MainActor [weak self] in
            guard let self else { return }
            let params: [String: JSONValue] = [
                "pane_id": .string(paneID.rawValue),
                "source": .string("visible"),
                "lines": .int(1),
            ]
            guard let data = try? await self.client.requestRaw("pane.read", params),
                  let line = Self.extractLastLine(data),
                  self.lastLineRequests.accepts(pane: paneID, revision: revision)
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

    /// Creates `pane`'s ghostty surface the first time or unparks a warm
    /// (previously parked) one; never a second surface for a pane that
    /// already has one, warm or not. A surface's size is its view's frame,
    /// never anything handed in here. Chained through `paneWork` (see its own
    /// doc comment), so a second attach racing a fresh one for the same pane
    /// can never reach the factory concurrently. Returns the surface (new,
    /// warm, or already visible) so a caller can hand it to `@State`; reading
    /// `ghosttySurface(for:)` back out independently would depend on whether
    /// a dictionary mutation buried inside a method call still registers as
    /// an `@Observable` access, which this sidesteps entirely.
    @discardableResult
    public func attachPane(_ pane: PaneID) async -> (any GhosttyPaneSurface)? {
        guard let ghosttyFactory else { return nil }
        parkedPanes.removeAll { $0 == pane }
        let previous = paneWork[pane]
        let task = Task { [weak self] in
            _ = await previous?.value
            guard let self else { return }
            await self.performAttach(pane: pane, factory: ghosttyFactory)
        }
        paneWork[pane] = task
        await task.value
        return ghosttySurfaces[pane]
    }

    /// PARKS `pane`'s ghostty surface -- called when the pane leaves the
    /// visible set (tab switch, split closed, window resize dropping it off
    /// screen). The surface itself is kept alive, with its bridge still
    /// attached and receiving frames, and marked occluded so libghostty stops
    /// drawing a pane nothing can see; `attachPane` reuses it, unparked, the
    /// moment the pane is visible again -- no flash, no fresh bridge/PTY.
    /// Only the warm cap's own eviction, or herdr no longer reporting this
    /// pane at all, tears a surface down for real (see
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
    }

    /// `pane`'s live ghostty surface, if it has one -- warm (parked) or
    /// visible. `PaneCellView` reads this at `init` to seed its `@State`
    /// synchronously, so a warm pane never renders the status card even for
    /// one frame.
    public func ghosttySurface(for pane: PaneID) -> (any GhosttyPaneSurface)? {
        ghosttySurfaces[pane]
    }

    private func performAttach(pane: PaneID, factory: any GhosttyPaneFactory) async {
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
            paneScrollSubscriber?.subscribe(pane: pane)
            return
        }
        // Both closures are the launcher-pristine contract's ghostty half:
        // see `GhosttyPaneFactory.makeSurface`'s doc comment. The screen-
        // activity one guards on `isPristineLauncherPane` itself before
        // ever touching the registry -- once ANY path (a keystroke, or this
        // one) has hidden the pane, every later call is a cheap no-op that
        // also tells the surface to stop reporting for good.
        let surface = await factory.makeSurface(
            for: pane,
            onUserInput: { [weak self] in self?.recordLauncherKeystroke(pane) },
            onScreenActivity: { [weak self] nonEmptyRowCount in
                guard let self, self.isPristineLauncherPane(pane) else { return false }
                self.recordLauncherScreenActivity(pane, nonEmptyRowCount: nonEmptyRowCount)
                return self.isPristineLauncherPane(pane)
            }
        )
        ghosttySurfaces[pane] = surface
        paneScrollSubscriber?.subscribe(pane: pane)
    }

    /// Marks `pane`'s surface occluded and moves it to the back of the warm
    /// queue -- never removed from `ghosttySurfaces`, which is the whole
    /// difference between this and `performTeardown`. Evicts the warm cap's
    /// overflow afterward, oldest park first.
    private func performPark(pane: PaneID) async {
        guard let surface = ghosttySurfaces[pane] else { return }
        surface.park()
        paneScrollSubscriber?.unsubscribe(pane: pane)
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
        paneScrollSubscriber?.unsubscribe(pane: pane)
        parkedPanes.removeAll { $0 == pane }
        await surface.detach()
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

    /// Sends `binary` to `pane` and submits it in one `send_input` call (the
    /// overlay's click contract), then hides the launcher for that pane
    /// immediately, same as a real keystroke would.
    ///
    /// The Enter rides `keys`, never a newline inside `text`: herdr wraps a
    /// non-empty `text` in a bracketed-paste sequence whenever the pane's
    /// program enabled it (a shell at a prompt does), and a newline inside
    /// that bracket reaches the line editor as a literal newline rather than
    /// accept-line, so the harness name would be typed and never run.
    /// `keys` is encoded outside the bracket.
    public func launchHarness(_ binary: String, in pane: PaneID) async {
        _ = try? await client.requestRaw(
            "pane.send_input",
            [
                "pane_id": .string(pane.rawValue),
                "text": .string(binary),
                "keys": .array([.string("Enter")]),
            ]
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

    /// Commits one divider drag's final ratio. Routed through `planExecutor`
    /// as a single-op `OpPlan`, same as `closePane`, so it lands in the undo
    /// journal for free -- `MutationEngine`'s own `simpleInverse` already
    /// knows `setSplitRatio`'s inverse (the prior ratio, read off the model
    /// before this ran). Never goes through `plan(dragging:onto:model:)`: a
    /// divider is not a `DragSubject`, so widening that planner's subject
    /// model for one gesture that resolves no drop target would be a net
    /// increase in surface for no shared behavior. Silently does nothing
    /// with no executor injected -- a divider drag with nowhere to send its
    /// op is the same "no seam configured" case `closePane` falls back on.
    public func setSplitRatio(tab: TabID, path: [Bool], ratio: Double) async {
        guard let planExecutor else { return }
        guard let undoJournal else {
            guard splitExists(tab: tab, path: path) else { return }
            await Self.setSplitRatio(tab: tab, path: path, ratio: ratio, executor: planExecutor, notify: noticeSink) { _ in }
            return
        }
        // Re-checked HERE, not by the caller before this was even queued:
        // a divider drag's own `ended()` can be reached from a release
        // monitor independent of whatever view started it (see
        // `DividerDragCoordinator`), so the path it captured at `began()`
        // may no longer name a real split by the time this actually runs --
        // herdr reshaped the tab mid-drag (a remote resize, another client
        // closing a pane), or this call sat behind an in-flight undo/redo
        // for long enough that it did. Committing anyway would land the
        // ratio on whatever split now occupies that path, plus an undo
        // entry naming it -- silently declining is the same choice
        // `HerdrStore.predictedLayout` already makes for its own optimistic
        // preview of this same op.
        await undoJournal.runExclusively { [weak self, noticeSink] in
            guard let self, self.splitExists(tab: tab, path: path) else { return }
            await Self.setSplitRatio(tab: tab, path: path, ratio: ratio, executor: planExecutor, notify: noticeSink, record: undoJournal.record)
        }
    }

    /// Whether `path` currently resolves to a real split in `tab`'s own
    /// layout, via the identical resolution `CanvasGeometry` and
    /// `HerdrStore.predictedLayout` already use (`splitPaths`, id-parsed
    /// first, structural fallback second) -- never re-derived a third way.
    private func splitExists(tab: TabID, path: [Bool]) -> Bool {
        guard let layout = model?.layouts[tab] else { return false }
        return CanvasGeometry.splitPaths(splits: layout.splits, area: layout.area).values.contains(path)
    }

    private static func setSplitRatio(
        tab: TabID, path: [Bool], ratio: Double, executor: any PlanExecuting,
        notify: @MainActor (String) -> Void, record: @MainActor (ExecutedPlan) -> Void
    ) async {
        let result = await executor.execute(OpPlan(ops: [.setSplitRatio(tab: tab, path: path, ratio: ratio)], label: "Resize split"))
        switch result {
        case .success(let executed):
            record(executed)
        case .failure(let failure):
            notify("Resize split failed: \(failure.message)")
        }
    }

    /// Runs one context-menu move/swap command: plans `subject` onto
    /// `target` against the live model, executes the resulting plan through
    /// `planExecutor`, and records the outcome in `undoJournal`. `.noOp`
    /// (e.g. a pane dropped onto its own tab) is silently ignored -- the
    /// menu already excludes the pane's own tab, so this is a defensive
    /// no-op rather than a path real menu selections take. `.notAttempted`
    /// covers the three guards below that never even reach the planner (no
    /// executor, no model, or the view model deallocated while queued behind
    /// an in-flight undo/redo) -- distinct from `.noOp` because nothing was
    /// planned at all, though callers today treat both identically (a silent
    /// spring-back). When an `undoJournal` is injected, this runs through its
    /// shared chain so it can never interleave with an in-flight `undo`/`redo`
    /// (a `record` call racing an in-flight `undo`'s own stack mutation would
    /// otherwise be able to wipe the redo stack mid-step).
    @discardableResult
    public func perform(subject: DragSubject, target: DropTarget) async -> DragOutcome {
        guard planExecutor != nil else { return .notAttempted }
        guard let undoJournal else {
            guard let model, let planExecutor else { return .notAttempted }
            return await Self.perform(
                subject: subject, target: target, model: model, executor: planExecutor, notify: noticeSink,
                record: { _ in }, follow: { [weak self] pane in await self?.jumpToHerdr(pane: pane) }
            )
        }
        // Reads `model` fresh once this closure actually runs, not at the
        // moment `perform` was called: queued behind an in-flight
        // undo/redo, the model can move on while this waits its turn, and
        // planning against a snapshot captured before the wait would plan
        // against a tab/workspace arrangement that no longer holds.
        var outcome = DragOutcome.notAttempted
        await undoJournal.runExclusively { [weak self] in
            guard let self, let model = self.model, let planExecutor = self.planExecutor else { return }
            outcome = await Self.perform(
                subject: subject, target: target, model: model, executor: planExecutor, notify: self.noticeSink,
                record: undoJournal.record, follow: { [weak self] pane in await self?.jumpToHerdr(pane: pane) }
            )
        }
        return outcome
    }

    private static func perform(
        subject: DragSubject, target: DropTarget, model: SessionModel,
        executor: any PlanExecuting, notify: @MainActor (String) -> Void, record: @MainActor (ExecutedPlan) -> Void,
        follow: @MainActor (PaneID) async -> Void
    ) async -> DragOutcome {
        switch plan(dragging: subject, onto: target, model: model) {
        case .failure(.noOp):
            return .noOp
        case .failure(.invalidCombination):
            notify("Can't move there")
            return .rejected("Can't move there")
        case .success(let opPlan):
            let result = await executor.execute(opPlan)
            switch result {
            case .success(let executed):
                record(executed)
                if case .pane(let pane) = subject, target.takesThePaneOffItsTab(pane, model: model) {
                    // The pane went somewhere the user is not looking; follow
                    // it there. Focusing it in herdr moves herdr's focused tab,
                    // which paddock's own selection already follows. A move
                    // across workspaces re-keys the pane, so the id to focus is
                    // the one herdr assigned.
                    await follow(executed.paneIDRemap[pane] ?? pane)
                }
                return .committed
            case .failure(let failure):
                let message = "\(opPlan.label) failed: \(failure.message)"
                notify(message)
                return .rejected(message)
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

extension DropTarget {
    /// A drop that moves `pane` out of the tab it is in, so the pane is no
    /// longer on screen once the drop commits.
    ///
    /// A pane target names a pane rather than a tab, and the grid can aim one
    /// at a mini pane of any tab, so which tab it lands in is the model's
    /// answer and not the target's shape alone.
    func takesThePaneOffItsTab(_ pane: PaneID, model: SessionModel) -> Bool {
        switch self {
        case .tabThumbnail, .newTab, .workspaceThumbnail, .newWorkspace:
            return true
        case .paneEdge(let target, _), .paneInterior(let target):
            guard let from = model.panes[pane]?.tabID, let into = model.panes[target]?.tabID else { return false }
            return from != into
        case .tabStrip, .workspaceRail, .moreTabs:
            return false
        }
    }
}
