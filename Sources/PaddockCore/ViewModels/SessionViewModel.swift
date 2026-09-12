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
    private var ghosttySurfaces: [PaneID: any GhosttyPaneSurface] = [:]
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

    // One gate for the whole session: the first unsupported
    // `pane.selection.read` reply hides deep history for every pane, not
    // just the one that discovered it.
    private let historyCapabilityGate = HistoryCapabilityGate()
    private var paneTerminals: [PaneID: PaneTerminal] = [:]
    private let paneLauncherRegistry = PaneLauncherRegistry()
    // Local mirror of each pane's `right_click` routing, seeded `false`
    // (herdr) to match `PaneRightClickTarget`'s own server-side default;
    // never read back from herdr, so a pane closed/reopened under the same
    // id would resume showing the last value THIS session set, not
    // necessarily the server's -- acceptable since paddock is the only
    // writer of this verb today.
    private var rightClickRoutedToPane: Set<PaneID> = []

    // `nil` only when no `layoutExportClient` was injected (a test double
    // that only implements `HerdrCommandClient`, say); every pane canvas
    // then reads `exportedLayout(for:)` as `nil` and `CanvasGeometry.resolved`
    // falls back to rect derivation for every tab, same as a per-tab fetch
    // failure would.
    private let layoutExportCoordinator: LayoutExportCoordinator?

    public init(
        client: any HerdrCommandClient,
        ghosttyFactory: (any GhosttyPaneFactory)? = nil,
        layoutExportClient: (any LayoutExportClient)? = nil
    ) {
        self.client = client
        self.ghosttyFactory = ghosttyFactory
        self.layoutExportCoordinator = layoutExportClient.map { LayoutExportCoordinator(client: $0) }
    }

    public var unsupportedBanner: ProtocolMismatch? {
        guard case .unsupported(let error) = connectionState,
              case .protocolTooOld(let found, let required) = error
        else { return nil }
        return ProtocolMismatch(found: found, required: required)
    }

    /// Called whenever `HerdrStore.model`/`connection` change. Selection only
    /// ever fills in from nil, so a later update (an unrelated `layoutUpdated`,
    /// or any event that leaves focus untouched) never resets a selection
    /// already derived from herdr's focus or set by a user jump.
    public func update(model: SessionModel?, connection: ConnectionState) {
        self.model = model
        connectionState = connection
        if selectedWorkspaceID == nil {
            selectedWorkspaceID = model?.focusedWorkspaceID
        }
        if selectedTabID == nil {
            selectedTabID = model?.focusedTabID
        }
        // The echo caught up: the model now agrees with what the click
        // predicted, so the prediction can stand down and let the model's
        // own field drive `resolvedFocusedPaneID` again.
        if optimisticFocusedPaneID != nil, model?.focusedPaneID == optimisticFocusedPaneID {
            optimisticFocusedPaneID = nil
        }
        refreshLayoutExports()
        reconcilePaneModeIfNeeded()
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

    // MARK: - ghostty pane attach (every visible pane, one surface for its whole life)

    /// Creates `pane`'s ghostty surface the first time, or resizes the
    /// existing one -- never a second surface for a pane that already has
    /// one. Chained through `paneWork` (see its own doc comment), so a
    /// resize racing a fresh attach for the same pane can never reach the
    /// factory concurrently. Returns the surface (new or existing) so a
    /// caller can hand it to `@State`, reading `ghosttySurface(for:)` back
    /// out independently would depend on whether a dictionary mutation
    /// buried inside a method call still registers as an `@Observable`
    /// access, which this sidesteps entirely.
    @discardableResult
    public func attachPane(_ pane: PaneID, cols: Int, rows: Int) async -> (any GhosttyPaneSurface)? {
        guard let ghosttyFactory, cols > 0, rows > 0 else { return nil }
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

    /// Tears down `pane`'s ghostty surface -- called when the pane leaves
    /// the visible set entirely (tab switch, split closed, window resize
    /// dropping it off-screen). Chained through `paneWork` like `attachPane`.
    public func detachPane(_ pane: PaneID) async {
        let previous = paneWork[pane]
        let task = Task { [weak self] in
            _ = await previous?.value
            await self?.performDetach(pane: pane)
        }
        paneWork[pane] = task
        await task.value
        if modeArmedPane == pane {
            modeArmedPane = nil
        }
    }

    /// `pane`'s live ghostty surface, if it has one.
    public func ghosttySurface(for pane: PaneID) -> (any GhosttyPaneSurface)? {
        ghosttySurfaces[pane]
    }

    private func performAttach(pane: PaneID, cols: Int, rows: Int, factory: any GhosttyPaneFactory) async {
        if let existing = ghosttySurfaces[pane] {
            existing.resize(cols: cols, rows: rows)
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

    private func performDetach(pane: PaneID) async {
        guard let surface = ghosttySurfaces.removeValue(forKey: pane) else { return }
        lastSentMode.removeValue(forKey: pane)
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

    // MARK: - per-pane headless terminal (deep history + pristine-launcher screen check)

    /// The shared deep-history helper for `pane`, created once and cached
    /// for its lifetime.
    public func paneTerminal(for pane: PaneRecord, cols: Int, rows: Int) -> PaneTerminal {
        if let existing = paneTerminals[pane.paneID] { return existing }
        let terminal = PaneTerminal(
            cols: cols, paneID: pane.paneID, client: client, historyCapability: historyCapabilityGate
        )
        paneTerminals[pane.paneID] = terminal
        return terminal
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

    /// Closes `pane` directly via `pane.close {pane_id}` -- a creation/
    /// destruction verb like `splitRight`, so no undo journal: closing is
    /// final the same way herdr's own close is.
    public func closePane(_ pane: PaneID) async {
        _ = try? await client.requestRaw("pane.close", ["pane_id": .string(pane.rawValue)])
    }

    /// Whether right-clicks in `pane` currently route to the pane's own
    /// program rather than herdr's context menu -- local mirror of the last
    /// `pane.input.set` this session sent, read by the context-menu
    /// checkmark.
    public func isRightClickRoutedToPane(_ pane: PaneID) -> Bool {
        rightClickRoutedToPane.contains(pane)
    }

    /// Flips `pane`'s right-click routing and sends the new state via
    /// `pane.input.set`. Optimistic like `jumpToHerdr(pane:)`: the local
    /// flag flips before the round trip so the menu's checkmark reflects
    /// intent immediately, and reverts if the request fails.
    public func toggleRightClickRouting(for pane: PaneID) async {
        let routeToPane = !rightClickRoutedToPane.contains(pane)
        if routeToPane {
            rightClickRoutedToPane.insert(pane)
        } else {
            rightClickRoutedToPane.remove(pane)
        }
        let target = routeToPane ? "pane" : "herdr"
        guard (try? await client.requestRaw(
            "pane.input.set", ["pane_id": .string(pane.rawValue), "right_click": .string(target)]
        )) != nil else {
            if routeToPane {
                rightClickRoutedToPane.remove(pane)
            } else {
                rightClickRoutedToPane.insert(pane)
            }
            return
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
