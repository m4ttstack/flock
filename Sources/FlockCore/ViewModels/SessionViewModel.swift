import Foundation
import Observation
import os

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
    /// The grid hover card's tails, one per pane it has opened on.
    public private(set) var paneTails: [PaneID: PaneTail] = [:]
    public private(set) var attentionToasts = AttentionToastStack()

    /// Written from inside view bodies, which must not invalidate the views
    /// reading it; `lastLines` is what they observe.
    @ObservationIgnored private var lastLineRequests = LastLineRequests()
    /// The panes with a tail read in flight, for the same reason and read the
    /// same way: `paneTails` is what the card observes.
    @ObservationIgnored private var tailReads: Set<PaneID> = []
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

    // Armed for every pane the model carries, disarmed as panes leave it.
    // `nil` when nothing was injected (a bare test double); pane, tab and
    // workspace status then only ever move on a fresh snapshot.
    private let paneAgentStatusSubscriber: (any PaneAgentStatusSubscribing)?
    private var armedAgentStatusFeeds: Set<PaneID> = []

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
    /// Injected so a test can place a transition inside or outside the
    /// attention stack's coalescing window without sleeping.
    @ObservationIgnored private let now: @MainActor () -> Date

    public init(
        client: any HerdrCommandClient,
        ghosttyFactory: (any GhosttyPaneFactory)? = nil,
        layoutExportClient: (any LayoutExportClient)? = nil,
        planExecutor: (any PlanExecuting)? = nil,
        undoJournal: UndoJournal? = nil,
        paneScrollSubscriber: (any PaneScrollSubscribing)? = nil,
        paneAgentStatusSubscriber: (any PaneAgentStatusSubscribing)? = nil,
        noticeSink: @escaping @MainActor (String) -> Void = { _ in },
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.client = client
        self.ghosttyFactory = ghosttyFactory
        self.layoutExportCoordinator = layoutExportClient.map { LayoutExportCoordinator(client: $0) }
        self.planExecutor = planExecutor
        self.undoJournal = undoJournal
        self.paneScrollSubscriber = paneScrollSubscriber
        self.paneAgentStatusSubscriber = paneAgentStatusSubscriber
        self.noticeSink = noticeSink
        self.now = now
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
    /// task's whole point), cheap enough that flock's view can just follow
    /// herdr's, the same way the rest of the session already does. Only an
    /// actual CHANGE of herdr's focused tab moves the selection -- comparing
    /// against the model's PREVIOUS `focusedTabID`, not against
    /// `selectedTabID` itself, is what lets a flock-initiated selection
    /// that currently differs from herdr's last-known focus persist through
    /// an unrelated update (a `layoutUpdated` that touches neither) instead
    /// of being stomped back to whatever herdr already was focused on. A
    /// followed tab brings its workspace along (`select(tab:)`): herdr's
    /// focus can land in another workspace, a pane followed after a drop
    /// into another workspace's tab, and a window showing that tab under the
    /// old workspace's rail and strip would show two workspaces at once.
    public func update(model: SessionModel?, connection: ConnectionState) {
        let previousFocusedTabID = self.model?.focusedTabID
        let previousModel = self.model
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
        landSelectionAfterClose(previous: previousModel)
        reconcileRenameTarget()
        refreshLayoutExports()
        reconcileClosedPanes()
        reconcileAgentStatusFeeds()
        reconcileAttentionToasts(previous: previousModel)
    }

    /// Moves the selection off a tab or workspace this update has closed, to
    /// wherever herdr's own model already moved (`CloseSelection`). Nothing
    /// else does: herdr's `tab.close` and `pane.close` answer with no
    /// `tab.focused` of their own, so a strip and canvas left on the closed id
    /// would show empty space until the five-minute resnapshot.
    ///
    /// A nil model is a gap in the connection, not a close, and is left alone
    /// for the same reason `reconcileRenameTarget` leaves it alone.
    private func landSelectionAfterClose(previous: SessionModel?) {
        guard let model, let previous else { return }
        let landing = CloseSelection.landing(
            for: CloseSelection.Selection(workspace: selectedWorkspaceID, tab: selectedTabID),
            before: previous, after: model
        )
        selectedWorkspaceID = landing.workspace
        selectedTabID = landing.tab
    }

    /// One feed per pane herdr reports, since herdr serves
    /// `pane.agent_status_changed` per pane id and nowhere else. A nil model
    /// (a dropped connection) disarms every feed; the next snapshot arms them
    /// again, each with its own probe.
    private func reconcileAgentStatusFeeds() {
        guard let paneAgentStatusSubscriber else { return }
        let known = Set((model?.panes ?? [:]).keys)
        for pane in known.subtracting(armedAgentStatusFeeds) {
            paneAgentStatusSubscriber.subscribe(pane: pane)
        }
        for pane in armedAgentStatusFeeds.subtracting(known) {
            paneAgentStatusSubscriber.unsubscribe(pane: pane)
        }
        armedAgentStatusFeeds = known
    }

    // MARK: - attention toasts

    /// Raises what the pane statuses moved to since the last snapshot, then
    /// withdraws whatever the new snapshot has made untrue. Panes are walked
    /// in id order so two transitions in one snapshot always stack the same
    /// way round.
    ///
    /// A herd's panes are skipped here rather than hidden in the stack view:
    /// a toast that is never made cannot reach the collapsed count, the
    /// "more" pill, or a Clear that would then look like it did nothing.
    private func reconcileAttentionToasts(previous: SessionModel?) {
        guard let model else {
            attentionToasts.clear()
            return
        }
        let raisedAt = now()
        if let previous {
            for paneID in model.panes.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
                guard let pane = model.panes[paneID],
                      let was = previous.panes[paneID]?.agentStatus,
                      let kind = AttentionToastStack.kind(from: was, to: pane.agentStatus),
                      paneID != resolvedFocusedPaneID,
                      !HerdWorkspace.isHerdPane(pane, in: model)
                else { continue }
                attentionToasts.raise(AttentionToast.make(kind: kind, pane: pane, model: model, raisedAt: raisedAt))
            }
        }
        withdrawSettledAttentionToasts(model: model, at: raisedAt)
    }

    /// A toast is a claim about a pane, so it goes the moment the claim stops
    /// holding: the pane has been read (it is the focused one), herdr no
    /// longer reports it, the pane turns out to be herd-run, or -- for a
    /// "needs input" toast -- it is no longer blocked. Herdglass withdraws
    /// its notification on the first of those; the others are flock's,
    /// because a toast here is clickable and a click on a stale one would
    /// jump somewhere pointless.
    ///
    /// Leaving `blocked` counts only once the toast is older than the
    /// coalescing window. Inside it, an agent that bounces off blocked and
    /// back is flapping, and withdrawing there would defeat the coalescing it
    /// exists for: the pane would get a brand new toast on the way back.
    /// Joining a herd carries no such grace: it is not a state the pane can
    /// bounce out of within the window.
    private func withdrawSettledAttentionToasts(model: SessionModel, at now: Date) {
        for toast in attentionToasts.toasts {
            guard let pane = model.panes[toast.paneID] else {
                attentionToasts.dismiss(pane: toast.paneID)
                continue
            }
            let answered = toast.kind == .needsInput
                && pane.agentStatus != .blocked
                && now.timeIntervalSince(toast.raisedAt) >= AttentionToastStack.coalescingWindow
            if toast.paneID == resolvedFocusedPaneID || answered
                || HerdWorkspace.isHerdPane(pane, in: model) {
                attentionToasts.dismiss(pane: toast.paneID)
            }
        }
    }

    /// Drops every finished toast whose six seconds are up, then re-runs the
    /// withdrawal pass. The stack's own ticker calls this; a hovered stack
    /// stops calling it, which is what hover-pauses-auto-dismiss means.
    ///
    /// The second half is not a tidy-up: "no longer blocked" only withdraws a
    /// toast once it is older than the coalescing window, and the snapshot
    /// that reported the pane calming down can easily arrive inside that
    /// window. Nothing else re-examines the toast when the grace expires, so
    /// without this a question the user answered in the herdr TUI a second
    /// after it was asked stays on screen until some unrelated event or the
    /// five-minute resnapshot moves the model.
    public func sweepAttentionToasts() {
        let at = now()
        attentionToasts.expire(at: at)
        if let model {
            withdrawSettledAttentionToasts(model: model, at: at)
        }
    }

    public func dismissAttentionToast(pane: PaneID) {
        attentionToasts.dismiss(pane: pane)
    }

    public func clearAttentionToasts() {
        attentionToasts.clear()
    }

    /// The three focus verbs the Interactions sheet names, each with this
    /// pane's own explicit id. A toast is the one thing in flock that jumps
    /// across a workspace boundary, so the workspace and the tab are focused
    /// in their own right rather than left for herdr to infer from the pane.
    public func jumpToAttentionToast(pane: PaneID) async {
        guard let toast = attentionToasts.toast(pane: pane) else { return }
        attentionToasts.dismiss(pane: pane)
        await jumpToHerdr(workspace: toast.workspaceID)
        await jumpToHerdr(tab: toast.tabID)
        await jumpToHerdr(pane: toast.paneID)
    }

    /// Closes the editor when herdr no longer carries what it is open on. A
    /// nil model is NOT that: it is a transient gap in the connection, the
    /// same reading `UndoJournal` gives it, so the editor survives a
    /// reconnect rather than losing a half-typed name to it.
    private func reconcileRenameTarget() {
        guard let renameTarget, let model, !renameTarget.exists(in: model) else { return }
        self.renameTarget = nil
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

    /// Peek's jump verb names only a pane; this looks up the workspace and
    /// tab that pane's OWN record carries and focuses all three, the same
    /// order `jumpToAttentionToast` uses. The verb itself moves nothing, so a
    /// pane the model no longer has (closed since the verb answered) sends no
    /// request rather than jumping a workspace or tab to nowhere.
    public func focusFromChat(pane id: PaneID) async {
        guard let record = model?.panes[id] else { return }
        await jumpToHerdr(workspace: record.workspaceID)
        await jumpToHerdr(tab: record.tabID)
        await jumpToHerdr(pane: record.paneID)
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

    /// The cached tail for the pane the grid's hover card is showing, reading
    /// it once when the card first asks. Keyed by pane alone, never by
    /// `revision`: a pane that prints changes nothing herdr reports about
    /// itself, so a revision-keyed tail would sit there while its pane ran.
    /// `refreshPaneTail` is what keeps it current for as long as the card is
    /// up.
    public func paneTail(for pane: PaneID) -> PaneTail? {
        if paneTails[pane] == nil {
            readTail(for: pane)
        }
        return paneTails[pane]
    }

    /// One tick of the open card's own cadence.
    public func refreshPaneTail(for pane: PaneID) {
        readTail(for: pane)
    }

    /// One read at a time per pane: a tick that arrives while the last read is
    /// still out leaves it to land rather than adding a second. The answer is
    /// kept whether or not the card is still open, so re-hovering a pane shows
    /// its last tail at once and refreshes behind it.
    private func readTail(for pane: PaneID) {
        guard tailReads.insert(pane).inserted else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let params: [String: JSONValue] = [
                "pane_id": .string(pane.rawValue),
                "source": .string("visible"),
                "lines": .int(PaneTailPolicy.readLines),
            ]
            let data = try? await self.client.requestRaw("pane.read", params)
            self.tailReads.remove(pane)
            guard let data, let text = Self.extractReadText(data) else { return }
            self.paneTails[pane] = PaneTailPolicy.make(from: text)
        }
    }

    /// `pane.read`'s payload sits under its own wrapper key, as every herdr
    /// success payload does; decoding `result.text` directly finds nothing and
    /// leaves the card blank with no error to show for it.
    static func extractReadText(_ data: Data) -> String? {
        struct Read: Decodable { let text: String }
        struct Result: Decodable { let read: Read }
        struct Envelope: Decodable { let result: Result }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { return nil }
        return envelope.result.read.text
    }

    static func extractLastLine(_ data: Data) -> String? {
        guard let text = extractReadText(data) else { return nil }
        let trimmed = text.trimmingCharacters(in: .newlines)
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

    /// What flock currently wants of its bridges, so a surface registered
    /// after the decision was made can be told as it appears. A bridge spawns
    /// HOLDING, so a pane first attached while flock is in the background
    /// would otherwise take that pane's lock and keep it until the next full
    /// activate-then-deactivate cycle: one pane refusing to follow the
    /// terminal while every other pane does, with nothing on screen to say so.
    @ObservationIgnored
    private var herdrHoldIntent: HoldCommand = .take

    /// Hands every pane flock holds back to herdr's own clients. PARKED
    /// panes are included and are the point: a parked surface keeps its bridge
    /// attached, so it holds that pane's resize lock just as a visible one
    /// does, and a workspace the user is looking at in the terminal is far
    /// more likely to be one of flock's parked tabs than its visible one.
    ///
    /// Not routed through `paneWork`: a hold command is one FIFO line with no
    /// reply, so it cannot race the attach/park chain the way a surface
    /// lifecycle step can, and making it wait behind an in-flight attach would
    /// only delay the handoff. `herdrHoldIntent` is what covers the surfaces
    /// that chain has not registered yet. Nothing here creates, parks or tears
    /// down a surface, so `ghosttySurfaces` and `parkedPanes` are untouched.
    public func releaseHerdrHold() {
        herdrHoldIntent = .release
        for surface in ghosttySurfaces.values { surface.releaseHerdrHold() }
        // Logged because a released pane is indistinguishable on screen from a
        // live one: it keeps showing its last frame, at whatever size herdr
        // rendered it, and no size flock computes can reach herdr until the
        // take. Two separate readings of "the pane will not resize" have
        // turned out to be this, so which state the window was in is worth a
        // line in the log rather than a guess afterwards.
        Self.holdLog.log("hold released panes=\(self.ghosttySurfaces.count)")
    }

    /// Takes every pane back at flock's own sizes. The counterpart of
    /// `releaseHerdrHold()`, over the same set.
    ///
    /// Re-asserted on every activation rather than only on the edge out of a
    /// release: a command dropped on a full FIFO (`PaneControlChannel.send`
    /// discards silently) would otherwise leave that one pane frozen with no
    /// later edge to correct it. A bridge that already holds ignores a repeat.
    public func takeHerdrHold() {
        herdrHoldIntent = .take
        for surface in ghosttySurfaces.values { surface.takeHerdrHold() }
        Self.holdLog.log("hold taken panes=\(self.ghosttySurfaces.count)")
    }

    private static let holdLog = Logger(subsystem: "dev.mattstack.flock", category: "hold")

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
        // All three closures are the launcher-pristine contract's ghostty
        // half: see `GhosttyPaneFactory.makeSurface`'s doc comment. The
        // screen-activity one hands back whether to keep reporting at all,
        // because counting a surface's rows is a full buffer scan: it stays
        // on only while the pane is still offering the launcher, or while a
        // clear it was just asked for has yet to land.
        let surface = await factory.makeSurface(
            for: pane,
            onUserInput: { [weak self] in self?.recordLauncherKeystroke(pane) },
            onClearRequested: { [weak self] in self?.recordLauncherClearRequested(pane) },
            onScreenActivity: { [weak self] nonEmptyRowCount in
                guard let self, self.wantsLauncherScreenActivity(pane) else { return false }
                self.recordLauncherScreenActivity(pane, nonEmptyRowCount: nonEmptyRowCount)
                return self.wantsLauncherScreenActivity(pane)
            }
        )
        ghosttySurfaces[pane] = surface
        // Only the release is asserted here: a bridge spawns holding, so a
        // take at registration would be a command every cold attach sends for
        // nothing.
        if herdrHoldIntent == .release { surface.releaseHerdrHold() }
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

    /// On the key path: `GhosttySurfaceView.keyDown` calls this for every real
    /// keystroke, so the seam is bumped only when the registry's answer
    /// actually moved. Every visible pane cell's body depends on that seam
    /// through `isPristineLauncherPane`, and the answer stops changing after
    /// the pane's first keystroke -- for a pane flock never created it never
    /// changes at all.
    public func recordLauncherKeystroke(_ pane: PaneID) {
        let wasPristine = paneLauncherRegistry.isPristine(pane)
        paneLauncherRegistry.recordKeystroke(pane)
        guard wasPristine else { return }
        launcherRegistryVersion += 1
    }

    /// The launcher-pristine contract's screen-activity half: a pane whose
    /// program prints real output, never typed into, also hides the
    /// overlay. `nonEmptyRowCount` is the surface's own retained-screen
    /// count (`GhosttySession.reportScreenActivityIfDue`); which counts are
    /// the shell still starting up, and which are the pane in use, is
    /// `PaneLauncherRegistry`'s answer.
    public func recordLauncherScreenActivity(_ pane: PaneID, nonEmptyRowCount: Int) {
        paneLauncherRegistry.recordScreenActivity(pane, nonEmptyRowCount: nonEmptyRowCount, at: now())
        launcherRegistryVersion += 1
    }

    /// The pane was asked to clear its screen. This shows nothing by itself:
    /// it opens the window in which the pane's screen dropping back to its
    /// settled size means the clear landed and the launcher can be offered
    /// again. A program that handled the key itself and repainted never makes
    /// that drop, so it keeps the overlay away.
    public func recordLauncherClearRequested(_ pane: PaneID) {
        paneLauncherRegistry.recordClearRequested(pane, at: now())
        launcherRegistryVersion += 1
    }

    /// Whether this pane's surface should still be counting its rows for the
    /// launcher. That count is a full buffer scan, so it is not left running
    /// on panes whose answer can no longer change.
    public func wantsLauncherScreenActivity(_ pane: PaneID) -> Bool {
        _ = launcherRegistryVersion
        return paneLauncherRegistry.wantsScreenActivity(pane, at: now())
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
    /// registering it as flock-created so the launcher can show on it --
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
        landIn(pane: newPaneID)
    }

    /// flock's own half of the `focus: true` every create request carries:
    /// the new pane is the input sink and the launcher's pristine pane from
    /// the moment herdr answers, rather than from whenever its focus echo
    /// arrives -- and if that echo never arrives, this is the only thing that
    /// ever put the user in what they just made.
    private func landIn(pane: PaneID) {
        optimisticFocusedPaneID = pane
        paneLauncherRegistry.registerFlockCreated(pane)
        launcherRegistryVersion += 1
    }

    /// The close herdr would escalate into a tab or a workspace, held while the
    /// confirmation is up. It carries the finished prompt so the view names
    /// what is about to go without a second model read.
    public private(set) var pendingClose: CloseConfirmation?

    /// Closes `subject` after the prompt was answered. The subject is a
    /// PARAMETER, never read back off `pendingClose`, for the reason
    /// `confirmGroupClose` states: the dialog clears its own presentation
    /// state as it dismisses, which runs before this call's async work does.
    public func confirmClose(_ subject: CloseSubject) async {
        pendingClose = nil
        await sendClose(subject)
    }

    public func cancelPendingClose() {
        pendingClose = nil
    }

    /// Closes `pane`, asking first when herdr would take the tab or the
    /// workspace with it -- a close is irreversible, and Close Pane sits one
    /// modifier from Cut. One pane among siblings goes straight out with
    /// nothing on screen.
    ///
    /// Every route to a pane close is this one call (the right-click row, the
    /// SwiftUI fallback menu and Cmd+Shift+X all dispatch through
    /// `PaneMenuAction.perform`), so the gate cannot be walked around.
    public func closePane(_ pane: PaneID) async {
        await close(.pane(pane))
    }

    /// Closes `tab`, asking first when it is its workspace's last and herdr
    /// would close the workspace with it. Both routes to the verb, the strip's
    /// hover close button and the tab menu's Close row, are this one call.
    ///
    /// The `.closeTab` ops a migration plan and a `MutationEngine` inverse
    /// build are deliberately NOT this: they name a tab the plan itself made,
    /// and a prompt in the middle of a drag or an undo would be asking the
    /// user about bookkeeping they never requested.
    public func closeTab(_ tab: TabID) async {
        await close(.tab(tab))
    }

    /// Without a model there is nothing to weigh, and the close goes as it
    /// always did.
    private func close(_ subject: CloseSubject) async {
        if let model {
            let consequence = CloseConsequence.of(subject, model: model)
            let busy = BusyPanes(closing: subject, consequence: consequence, model: model)
            if let confirmation = consequence.confirmation(closing: subject, busy: busy) {
                pendingClose = confirmation
                return
            }
        }
        await sendClose(subject)
    }

    private func sendClose(_ subject: CloseSubject) async {
        switch subject {
        case .pane(let pane):
            await sendPaneClose(pane)
        case .tab(let tab):
            await run(OpPlan(ops: [.closeTab(tab)], label: "Close tab"))
        }
    }

    /// Routed through `planExecutor` as a single-op `OpPlan` when one is
    /// injected, so the close still lands in the undo journal -- its inverse
    /// is empty and `ExecutedPlan.irreversible` names the close, so undoing it
    /// surfaces "nothing to undo for a close" rather than silently doing
    /// nothing. Falls back to a raw `pane.close` send when no executor was
    /// injected (test doubles that only supply a bare client). When an
    /// `undoJournal` is also injected, this runs through its shared chain (see
    /// `UndoJournal.runExclusively`) so it can never interleave with an
    /// in-flight `perform`/`undo`/`redo`.
    private func sendPaneClose(_ pane: PaneID) async {
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
    /// otherwise be able to wipe the redo stack mid-step). `board` names the
    /// workspaces the rail sets aside in its Board section, which a rail slot
    /// is counted without.
    @discardableResult
    public func perform(subject: DragSubject, target: DropTarget, board: BoardWorkspaceNames? = nil) async -> DragOutcome {
        guard planExecutor != nil else { return .notAttempted }
        guard let undoJournal else {
            guard let model, let planExecutor else { return .notAttempted }
            return await Self.perform(
                subject: subject, target: target, model: model, board: board, executor: planExecutor, notify: noticeSink,
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
                subject: subject, target: target, model: model, board: board, executor: planExecutor, notify: self.noticeSink,
                record: undoJournal.record, follow: { [weak self] pane in await self?.jumpToHerdr(pane: pane) }
            )
        }
        return outcome
    }

    private static func perform(
        subject: DragSubject, target: DropTarget, model: SessionModel, board: BoardWorkspaceNames?,
        executor: any PlanExecuting, notify: @MainActor (String) -> Void, record: @MainActor (ExecutedPlan) -> Void,
        follow: @MainActor (PaneID) async -> Void
    ) async -> DragOutcome {
        switch plan(dragging: subject, onto: target, model: model, board: board) {
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
                    // which flock's own selection already follows. A move
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

    // MARK: - rename, clear, zoom, close, create

    /// What the one inline rename editor is open on, or `nil` when none is.
    /// Views both render the editor from this and disarm their own drag while
    /// it names them, so a press inside the field can never start a drag.
    public private(set) var renameTarget: RenameTarget?

    /// Whether an inline editor is on screen right now, which is what decides
    /// whether a pane's terminal may hold the keyboard. Deliberately not
    /// `renameTarget != nil`: a target outlives its view whenever herdr's
    /// focus moves to another workspace or tab, and a terminal that yielded to
    /// a view nobody is drawing would leave the window with no first responder
    /// at all (`RenameEditor.isOnScreen`).
    public var renameEditorIsOnScreen: Bool {
        RenameEditor.isOnScreen(
            renameTarget, selectedWorkspace: selectedWorkspaceID, selectedTab: selectedTabID, model: model
        )
    }

    /// The workspace whose plain `workspace.close` came back
    /// `workspace_group_close_required`, held while the confirmation is up.
    /// `confirmGroupClose(_:)` re-asks with `closeGroup: true`. It carries the
    /// label so the prompt can name what it is about to destroy without a
    /// second model read in the view.
    public struct PendingGroupClose: Equatable, Identifiable, Sendable {
        public let workspaceID: WorkspaceID
        public let label: String
        /// Busy panes in the PRIMARY workspace only. The linked worktree
        /// workspaces this close also takes cannot be counted: nothing in the
        /// model says which they are.
        public let busy: BusyPanes

        public var id: WorkspaceID { workspaceID }

        public init(workspaceID: WorkspaceID, label: String, busy: BusyPanes = .none) {
            self.workspaceID = workspaceID
            self.label = label
            self.busy = busy
        }
    }

    public private(set) var pendingGroupClose: PendingGroupClose?

    public func beginRename(_ target: RenameTarget) {
        renameTarget = target
    }

    /// What the rename key opens on right now, or `nil` when nothing is
    /// selected -- the menu item reads this both to enable itself and to know
    /// what to open.
    public var renameShortcutTarget: RenameTarget? {
        RenameShortcut.target(
            focusedPane: resolvedFocusedPaneID, selectedTab: selectedTabID, selectedWorkspace: selectedWorkspaceID
        )
    }

    /// The rename key's whole behavior: open the editor on whatever
    /// `renameShortcutTarget` names, or do nothing.
    public func beginRenameFromShortcut() {
        guard let target = renameShortcutTarget else { return }
        beginRename(target)
    }

    public func cancelRename() {
        renameTarget = nil
    }

    /// The text the editor opens with, per `RenameEditor`'s rules.
    public func renameText(for target: RenameTarget) -> String {
        RenameEditor.initialText(for: target, model: model)
    }

    /// Commits whatever the editor holds and closes it. A commit that
    /// `RenameEditor` refuses (blank once trimmed, unchanged, or a target the
    /// model no longer carries) closes the editor and issues nothing.
    public func commitRename(_ text: String, for target: RenameTarget) async {
        if renameTarget == target {
            renameTarget = nil
        }
        guard let op = RenameEditor.commit(text, for: target, model: model) else { return }
        await run(OpPlan(ops: [op], label: RenameEditor.planLabel(for: target)))
    }

    /// Drops a pane's manual label so its terminal title shows again
    /// (`pane.rename` with a null label). Offered only while the pane has one,
    /// so a pane without is a no-op rather than a wire call herdr would
    /// answer with no change.
    public func clearPaneName(_ pane: PaneID) async {
        guard model?.panes[pane]?.label != nil else { return }
        await run(OpPlan(ops: [.renamePane(pane, nil)], label: "Clear pane name"))
    }

    /// Toggles herdr's zoom for `pane`'s tab. Deliberately NOT journaled: its
    /// own inverse is itself, so an entry here would only ever be a dead undo
    /// step that reports nothing to undo.
    public func toggleZoom(_ pane: PaneID) async {
        await run(OpPlan(ops: [.zoom(pane, mode: .toggle)], label: "Zoom pane"), recordsUndo: false)
    }

    /// Asks herdr to close `workspace` WITHOUT its group. herdr refuses that
    /// for a group primary with open linked-worktree workspaces
    /// (`workspace_group_close_required`), which is the one failure this
    /// raises no notice for: it parks the workspace in `pendingGroupClose`
    /// for the view to confirm, and `confirmGroupClose` re-asks with the
    /// group included.
    public func closeWorkspace(_ workspace: WorkspaceID) async {
        await closeWorkspace(workspace, closeGroup: false)
    }

    /// Re-asks for `workspace` with its group included. The id is a
    /// PARAMETER, never read back off `pendingGroupClose`: a confirmation
    /// dialog clears its own presentation state as it dismisses, which runs
    /// before this call's async work does, so reading the latch here would
    /// find it already nil and close nothing at all.
    public func confirmGroupClose(_ workspace: WorkspaceID) async {
        pendingGroupClose = nil
        await closeWorkspace(workspace, closeGroup: true)
    }

    public func cancelPendingGroupClose() {
        pendingGroupClose = nil
    }

    private func closeWorkspace(_ workspace: WorkspaceID, closeGroup: Bool) async {
        let plan = OpPlan(
            ops: [.closeWorkspace(workspace, closeGroup: closeGroup)],
            label: closeGroup ? "Close workspace group" : "Close workspace"
        )
        let label = model?.workspaces.first { $0.workspaceID == workspace }?.label ?? workspace.rawValue
        await run(plan) { [weak self] failure in
            guard failure.code == "workspace_group_close_required" else { return false }
            // Counted here rather than in the view, and at refusal time
            // rather than at confirm time, so the number describes the
            // session the user is being asked about.
            let busy = self?.model.map { BusyPanes(inWorkspace: workspace, model: $0) } ?? BusyPanes.none
            self?.pendingGroupClose = PendingGroupClose(workspaceID: workspace, label: label, busy: busy)
            return true
        }
    }

    /// Creation is a direct client call, not a planned op: herdr has no
    /// inverse for it that flock could journal (closing a tab it created is
    /// not the same as never having created it), so v1 leaves it out of undo
    /// entirely rather than record an entry that cannot be undone. The
    /// FAILURE still goes through `noticeSink` like every other mutation:
    /// the strip and rail create from a zone that draws nothing, so a
    /// swallowed failure is indistinguishable from a click that missed, and
    /// the natural retry spawns a second real shell.
    public func createTab(in workspace: WorkspaceID) async {
        await create("tab.create", ["workspace_id": .string(workspace.rawValue), "focus": .bool(true)], label: "New tab")
    }

    /// `source_workspace_id` is what herdr reads the new workspace's cwd
    /// policy from, so a workspace created from the rail follows whatever the
    /// one on screen was pointed at.
    public func createWorkspace() async {
        var params: [String: JSONValue] = ["focus": .bool(true)]
        if let source = selectedWorkspaceID {
            params["source_workspace_id"] = .string(source.rawValue)
        }
        await create("workspace.create", params, label: "New workspace")
    }

    /// Both create responses name the tab that was made and its root pane
    /// (`workspace.create` answers with the first tab of the new workspace),
    /// which is what lets the selection move on the answer rather than on the
    /// echo. A response this cannot read leaves the selection where it was,
    /// which is what every create did before: herdr's own focus echo is then
    /// the only thing that moves it.
    private func create(_ method: String, _ params: [String: JSONValue], label: String) async {
        do {
            let data = try await client.requestRaw(method, params)
            guard let created = Self.extractCreatedTab(data) else { return }
            selectedWorkspaceID = created.workspaceID
            selectedTabID = created.tabID
            landIn(pane: created.rootPaneID)
        } catch {
            noticeSink("\(label) failed: \(Self.describe(error))")
        }
    }

    private static func describe(_ error: Error) -> String {
        guard let clientError = error as? HerdrClientError else { return String(describing: error) }
        switch clientError {
        case let .server(code, message): return message.isEmpty ? code : message
        case let .transport(message): return message
        case let .timedOut(method): return "\(method) got no answer from herdr"
        case let .protocolTooOld(found, required): return "protocol \(found), need \(required)"
        }
    }

    // MARK: - keyboard move and swap (the drag's own targets, compiled by the planner)

    /// Moves `pane` against its neighbor on `direction`'s side, through the
    /// same planner and executor a drag onto that neighbor's edge uses.
    /// Silent when nothing lies that way.
    public func movePane(_ pane: PaneID, toward direction: PaneDirection) async {
        await aim(pane, toward: direction, using: PaneNeighbors.moveTarget)
    }

    /// Trades `pane` with its neighbor on `direction`'s side. Same neighbor
    /// as a move, read as a pane interior, which the planner turns into a
    /// same-tab `pane.swap` rather than the move's temp-tab bounce.
    public func swapPane(_ pane: PaneID, toward direction: PaneDirection) async {
        await aim(pane, toward: direction, using: PaneNeighbors.swapTarget)
    }

    /// The menu-command forms: whichever pane is focused right now.
    public func moveFocusedPane(toward direction: PaneDirection) async {
        guard let pane = resolvedFocusedPaneID else { return }
        await movePane(pane, toward: direction)
    }

    public func swapFocusedPane(toward direction: PaneDirection) async {
        guard let pane = resolvedFocusedPaneID else { return }
        await swapPane(pane, toward: direction)
    }

    /// Whether the focused pane has a neighbor on `direction`'s side at all,
    /// so both keyboard commands can disable themselves rather than fail
    /// silently. One predicate for both: a move and a swap aim at the same
    /// neighbor and differ only in what they do once there.
    public func focusedPaneHasNeighbor(toward direction: PaneDirection) -> Bool {
        guard let pane = resolvedFocusedPaneID, let layout = layout(holding: pane) else { return false }
        return PaneNeighbors.pane(pane, toward: direction, in: layout) != nil
    }

    private func aim(
        _ pane: PaneID, toward direction: PaneDirection,
        using target: (PaneID, PaneDirection, LayoutSnapshot) -> DropTarget?
    ) async {
        guard let layout = layout(holding: pane), let target = target(pane, direction, layout) else { return }
        await perform(subject: .pane(pane), target: target)
    }

    private func layout(holding pane: PaneID) -> LayoutSnapshot? {
        guard let tab = model?.panes[pane]?.tabID else { return nil }
        return model?.layouts[tab]
    }

    // MARK: - shared plan execution for hand-built plans

    /// Runs one hand-built (never planner-produced) plan the way every menu
    /// command does: through `planExecutor`, recorded in `undoJournal` unless
    /// `recordsUndo` says otherwise, with a failure surfaced as a notice
    /// unless `handleFailure` claims it. Does nothing with no executor
    /// injected -- the same "no seam configured" case `setSplitRatio` falls
    /// back on. Runs inside the journal's shared chain so it can never
    /// interleave with an in-flight `perform`/`undo`/`redo`.
    private func run(
        _ plan: OpPlan, recordsUndo: Bool = true,
        handleFailure: @escaping @MainActor (OpFailure) -> Bool = { _ in false }
    ) async {
        guard let planExecutor else { return }
        guard let undoJournal else {
            await Self.run(plan, executor: planExecutor, notify: noticeSink, record: { _ in }, handleFailure: handleFailure)
            return
        }
        await undoJournal.runExclusively { [noticeSink] in
            await Self.run(
                plan, executor: planExecutor, notify: noticeSink,
                record: recordsUndo ? undoJournal.record : { _ in }, handleFailure: handleFailure
            )
        }
    }

    private static func run(
        _ plan: OpPlan, executor: any PlanExecuting, notify: @MainActor (String) -> Void,
        record: @MainActor (ExecutedPlan) -> Void, handleFailure: @MainActor (OpFailure) -> Bool
    ) async {
        switch await executor.execute(plan) {
        case .success(let executed):
            record(executed)
        case .failure(let failure):
            guard !handleFailure(failure) else { return }
            notify("\(plan.label) failed: \(failure.message)")
        }
    }

    /// `pane.split`'s response nests the new pane's id under a `"pane"` key
    /// (verified against herdr's `PaneSplitResult` and pinned by
    /// `spikes/lib/seed-layout.sh`'s own `.result.pane.pane_id` read).
    /// The ids a `tab.create`/`workspace.create` answer carries.
    private struct CreatedTab {
        let workspaceID: WorkspaceID
        let tabID: TabID
        let rootPaneID: PaneID
    }

    private static func extractCreatedTab(_ data: Data) -> CreatedTab? {
        struct TabPayload: Decodable {
            let tabID: TabID
            let workspaceID: WorkspaceID
            enum CodingKeys: String, CodingKey {
                case tabID = "tab_id"
                case workspaceID = "workspace_id"
            }
        }
        struct PanePayload: Decodable {
            let paneID: PaneID
            enum CodingKeys: String, CodingKey { case paneID = "pane_id" }
        }
        struct Result: Decodable {
            let tab: TabPayload
            let rootPane: PanePayload
            enum CodingKeys: String, CodingKey {
                case tab
                case rootPane = "root_pane"
            }
        }
        struct Envelope: Decodable { let result: Result }
        guard let result = try? JSONDecoder().decode(Envelope.self, from: data).result else { return nil }
        return CreatedTab(workspaceID: result.tab.workspaceID, tabID: result.tab.tabID, rootPaneID: result.rootPane.paneID)
    }

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
