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

/// The subset of `ObserveSupervisor` the view-model needs to drive live
/// attach; a test double substitutes for it in `SessionViewModelTests`
/// without spawning real `herdr` child processes.
public protocol PaneObserveAttaching: Sendable {
    func attach(_ pane: PaneID, cols: Int, rows: Int) async -> AsyncStream<TerminalFrame>
    func reattach(_ pane: PaneID, cols: Int, rows: Int) async
    func detach(_ pane: PaneID) async
}

extension ObserveSupervisor: PaneObserveAttaching {}

/// A one-shot handoff for a newly attached pane: backfill ANSI (nil when the
/// pane.read failed or returned nothing) to feed first, then the live frame
/// stream. Returned only from the FIRST attach of a pane; a later dims
/// change reattaches in place and returns nil, since `ObserveSupervisor`
/// hands the SAME continuation to the new session -- the stream a caller is
/// already iterating keeps delivering, just at the new size.
public struct PaneLiveFeed: Sendable {
    public let backfillANSI: Data?
    /// How many lines `backfillANSI` was requested for (`pane.read`'s own
    /// `lines` param) -- deep history's contiguity anchor. `nil` alongside
    /// a `nil` `backfillANSI`.
    public let backfillLineCount: Int?
    public let frames: AsyncStream<TerminalFrame>

    public init(backfillANSI: Data?, backfillLineCount: Int? = nil, frames: AsyncStream<TerminalFrame>) {
        self.backfillANSI = backfillANSI
        self.backfillLineCount = backfillLineCount
        self.frames = frames
    }
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
    private var attachedDims: [PaneID: (cols: Int, rows: Int)] = [:]
    // One chained task per pane: every attach/reattach/detach request for a
    // pane waits for whatever request came immediately before it (for that
    // SAME pane only -- other panes are unaffected) before touching
    // `observeAttacher`. This is what actually closes the reentrancy hole a
    // simple "recheck after await" guard cannot: once a `detach()` call is
    // issued there is no way to un-issue it, so an attach and a detach for
    // the same pane must never reach `observeAttacher` concurrently in the
    // first place. Not pruned as requests settle -- bounded by how many
    // distinct panes have ever existed in the session, not by request
    // volume, so this does not grow unbounded in practice.
    private var paneWork: [PaneID: Task<PaneLiveFeed?, Never>] = [:]
    private let client: any HerdrCommandClient
    private let observeAttacher: (any PaneObserveAttaching)?
    private let ghosttyFactory: (any GhosttyPaneFactory)?
    // The focused pane's live surface, keyed by pane so a stale surface from
    // a pane that has since lost focus is never mistaken for the current
    // one. Attach/detach for a given pane always goes through `paneWork`
    // (the SAME chain the observe path uses), so a focus flip-flop can never
    // race an observe attach/detach against a ghostty attach/detach for that
    // pane.
    private var ghosttySurfaces: [PaneID: any GhosttyPaneSurface] = [:]

    // One gate for the whole session: the first unsupported
    // `pane.selection.read` reply hides deep history for every pane, not
    // just the one that discovered it.
    private let historyCapabilityGate = HistoryCapabilityGate()
    private var paneTerminals: [PaneID: PaneTerminal] = [:]
    private var inputRouters: [PaneID: InputRouter] = [:]
    private let paneLauncherRegistry = PaneLauncherRegistry()
    // Local mirror of each pane's `right_click` routing, seeded `false`
    // (herdr) to match `PaneRightClickTarget`'s own server-side default;
    // never read back from herdr, so a pane closed/reopened under the same
    // id would resume showing the last value THIS session set, not
    // necessarily the server's -- acceptable since paddock is the only
    // writer of this verb today.
    private var rightClickRoutedToPane: Set<PaneID> = []

    public init(
        client: any HerdrCommandClient,
        observeAttacher: (any PaneObserveAttaching)? = nil,
        ghosttyFactory: (any GhosttyPaneFactory)? = nil
    ) {
        self.client = client
        self.observeAttacher = observeAttacher
        self.ghosttyFactory = ghosttyFactory
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
    }

    /// What views should treat as "the focused pane": the optimistic click
    /// target while a `pane.focus` round trip is in flight (or has not yet
    /// echoed back), else the model's own field. Painting from this instead
    /// of `model?.focusedPaneID` directly is what makes the accent ring move
    /// on the same frame as the click rather than 24-100+ms later.
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

    // MARK: - live attach

    /// Attaches `pane` live at `cols`x`rows`, or reattaches in place if it is
    /// already attached at different dims. `cols`/`rows` must be the pane's
    /// real cell size -- callers pass the layout's own `CellRect.width`/
    /// `.height` (already in terminal cells), never a pixel frame, matching
    /// `ObserveSupervisor`'s documented contract.
    ///
    /// Chained through `paneWork` (see its doc comment): a resize arriving
    /// while an earlier attach for the SAME pane is still awaiting its
    /// backfill RPC does not race it. The new request waits for the earlier
    /// one to fully settle, then reconciles from whatever state that left
    /// behind toward its own (newer) dims -- so the observe child always
    /// ends up at the most recently requested size, never a stale one a
    /// resize already superseded.
    public func beginOrUpdateLiveAttach(pane: PaneRecord, cols: Int, rows: Int) async -> PaneLiveFeed? {
        guard let observeAttacher, cols > 0, rows > 0 else { return nil }
        let paneID = pane.paneID
        let previous = paneWork[paneID]
        let task = Task { [weak self] () -> PaneLiveFeed? in
            _ = await previous?.value
            guard let self else { return nil }
            return await self.performAttach(pane: pane, cols: cols, rows: rows, observeAttacher: observeAttacher)
        }
        paneWork[paneID] = task
        return await task.value
    }

    /// Detaches a pane that left the visible set (tab switch, split closed,
    /// window resize dropping it off-screen). Chained through the same
    /// `paneWork` queue as attach/reattach, for the same reason: a detach
    /// fired from `onDisappear` must wait for any attach already in flight
    /// for this pane to finish before it can safely tear anything down --
    /// otherwise a fast reappear's fresh attach can install a new session
    /// that this (by-then-stale) detach then kills, since once `detach()`
    /// is issued there is no way to un-issue it.
    public func endLiveAttach(pane: PaneID) async {
        guard let observeAttacher else { return }
        let previous = paneWork[pane]
        let task = Task { [weak self] () -> PaneLiveFeed? in
            _ = await previous?.value
            await self?.performDetach(pane: pane, observeAttacher: observeAttacher)
            return nil
        }
        paneWork[pane] = task
        _ = await task.value
    }

    /// Runs only after every request queued ahead of it (for this pane) has
    /// fully settled, so `attachedDims[pane.paneID]` reflects the true
    /// current state -- never a value a since-superseded request captured.
    private func performAttach(
        pane: PaneRecord, cols: Int, rows: Int, observeAttacher: any PaneObserveAttaching
    ) async -> PaneLiveFeed? {
        if let existing = attachedDims[pane.paneID] {
            guard existing != (cols, rows) else { return nil }
            attachedDims[pane.paneID] = (cols, rows)
            await observeAttacher.reattach(pane.paneID, cols: cols, rows: rows)
            return nil
        }
        attachedDims[pane.paneID] = (cols, rows)
        let backfill = await fetchBackfillANSI(for: pane, cols: cols, rows: rows)
        // Seeded here, synchronously before this feed ever reaches a view,
        // rather than from `TerminalRepresentable.makeNSView`: the deep
        // history region is a VStack SIBLING of the terminal representable,
        // declared ABOVE it, so its own `onAppear` can fire (and call
        // `loadOlderHistory`) before an NSViewRepresentable's `makeNSView`
        // ever runs -- reading `backfillLineCount` as still its `0` default
        // and anchoring the first chunk at the pane's total row count,
        // duplicating whatever backfill goes on to show once seeded.
        //
        // `lineCount` is deliberately NOT passed here: `backfill.lines` is
        // the REQUESTED `pane.read` `lines` value, not a promise of how many
        // rows actually came back. herdr's real recent-read range can return
        // fewer (see `seedBackfill`'s own doc), so `PaneTerminal` measures
        // the real row count from `backfill.data` itself.
        if let backfill {
            paneTerminal(for: pane, cols: cols, rows: rows).seedBackfill(ansi: backfill.data)
        }
        let frames = await observeAttacher.attach(pane.paneID, cols: cols, rows: rows)
        return PaneLiveFeed(backfillANSI: backfill?.data, backfillLineCount: backfill?.lines, frames: frames)
    }

    private func performDetach(pane: PaneID, observeAttacher: any PaneObserveAttaching) async {
        guard attachedDims.removeValue(forKey: pane) != nil else { return }
        await observeAttacher.detach(pane)
    }

    // MARK: - ghostty control-plane attach (focused pane only)

    /// Creates `pane`'s ghostty surface the first time, or resizes the
    /// existing one -- never a second surface for a pane that already has
    /// one, matching the observe path's own "same pane, new dims" contract.
    /// Chained through the same `paneWork` entry the observe path uses (see
    /// its own doc comment), so a pane transitioning between renderers can
    /// never have both an observe attach and a ghostty attach in flight at
    /// once. Returns the surface (new or existing) so a caller can hand it
    /// to `@State`, the same reactivity path `feed` already uses for the
    /// observe side -- reading `ghosttySurface(for:)` back out independently
    /// would depend on whether a dictionary mutation buried inside a method
    /// call still registers as an `@Observable` access, which this sidesteps
    /// entirely.
    @discardableResult
    public func beginOrUpdateGhosttyAttach(pane: PaneID, cols: Int, rows: Int) async -> (any GhosttyPaneSurface)? {
        guard let ghosttyFactory, cols > 0, rows > 0 else { return nil }
        let previous = paneWork[pane]
        let task = Task { [weak self] () -> PaneLiveFeed? in
            _ = await previous?.value
            await self?.performGhosttyAttach(pane: pane, cols: cols, rows: rows, factory: ghosttyFactory)
            return nil
        }
        paneWork[pane] = task
        _ = await task.value
        return ghosttySurfaces[pane]
    }

    /// Tears down `pane`'s ghostty surface, if it has one -- called when the
    /// pane loses focus (falling back to the observe path) or leaves the
    /// visible set entirely. Chained through `paneWork` like `endLiveAttach`.
    public func endGhosttyAttach(pane: PaneID) async {
        let previous = paneWork[pane]
        let task = Task { [weak self] () -> PaneLiveFeed? in
            _ = await previous?.value
            await self?.performGhosttyDetach(pane: pane)
            return nil
        }
        paneWork[pane] = task
        _ = await task.value
    }

    /// `pane`'s live ghostty surface, if it has one.
    public func ghosttySurface(for pane: PaneID) -> (any GhosttyPaneSurface)? {
        ghosttySurfaces[pane]
    }

    /// `async` (despite a synchronous body) purely so the `Task` closures
    /// above can `await` it: that is what lets a synchronous, MainActor-only
    /// call run safely from a closure whose own isolation is not otherwise
    /// pinned to this actor, matching `performAttach`/`performDetach`'s own
    /// shape.
    private func performGhosttyAttach(pane: PaneID, cols: Int, rows: Int, factory: any GhosttyPaneFactory) async {
        if let existing = ghosttySurfaces[pane] {
            existing.resize(cols: cols, rows: rows)
            return
        }
        // The closure is the launcher-pristine contract's ghostty half: see
        // `GhosttyPaneFactory.makeSurface`'s doc comment.
        ghosttySurfaces[pane] = await factory.makeSurface(for: pane, cols: cols, rows: rows) { [weak self] in
            self?.recordLauncherKeystroke(pane)
        }
    }

    private func performGhosttyDetach(pane: PaneID) async {
        guard let surface = ghosttySurfaces.removeValue(forKey: pane) else { return }
        await surface.detach()
    }

    // MARK: - renderer swap (single call per pane, cancellation-safe)

    /// Swaps `pane` onto the ghostty transport in ONE `paneWork` step:
    /// attaches (or resizes) its ghostty surface, then -- inside that SAME
    /// step -- tears down whatever observe attach `attachedDims` says this
    /// pane ACTUALLY still carries, read at the moment this step runs on the
    /// chain, never from anything a caller believes. `PaneCellView` calls
    /// this exactly once per render identity instead of two separate
    /// attach/detach calls: SwiftUI's `.task(id:)` cancellation is
    /// cooperative, so a superseded task body for this pane can keep running
    /// to completion after a fast flip-flop, and if attach and detach were
    /// two separate enqueues, a stale body's own (delayed) detach call could
    /// land on `paneWork` AFTER a fresher call's attach and undo it, settling
    /// the pane with neither transport. Folding both into one step removes
    /// that window entirely: a stale call's own detach decision is made
    /// after it, not a fresher call, is next on the chain, so its second
    /// pass (if a fresher call is already chained behind it) finds nothing
    /// stale to act on and a fresher call chained behind IT always re-reads
    /// current truth before deciding anything.
    @discardableResult
    public func swapToGhostty(pane: PaneID, cols: Int, rows: Int) async -> (any GhosttyPaneSurface)? {
        guard let ghosttyFactory, cols > 0, rows > 0 else { return nil }
        let previous = paneWork[pane]
        let task = Task { [weak self] () -> PaneLiveFeed? in
            _ = await previous?.value
            guard let self else { return nil }
            await self.performGhosttyAttach(pane: pane, cols: cols, rows: rows, factory: ghosttyFactory)
            if let observeAttacher = self.observeAttacher, self.attachedDims[pane] != nil {
                await self.performDetach(pane: pane, observeAttacher: observeAttacher)
            }
            return nil
        }
        paneWork[pane] = task
        _ = await task.value
        return ghosttySurfaces[pane]
    }

    /// Symmetric: attaches (or reattaches) `pane`'s observe feed, then tears
    /// down whatever ghostty surface `ghosttySurfaces` says this pane
    /// actually still carries -- same single-step reasoning as
    /// `swapToGhostty`.
    public func swapToObserve(pane: PaneRecord, cols: Int, rows: Int) async -> PaneLiveFeed? {
        guard let observeAttacher, cols > 0, rows > 0 else { return nil }
        let paneID = pane.paneID
        let previous = paneWork[paneID]
        let task = Task { [weak self] () -> PaneLiveFeed? in
            _ = await previous?.value
            guard let self else { return nil }
            let feed = await self.performAttach(pane: pane, cols: cols, rows: rows, observeAttacher: observeAttacher)
            if self.ghosttySurfaces[paneID] != nil {
                await self.performGhosttyDetach(pane: paneID)
            }
            return feed
        }
        paneWork[paneID] = task
        return await task.value
    }

    /// `pane.read {source:"recent", format:"ansi", lines:N}` per spike 4's
    /// backfill recipe. Alt-screen heuristic: `PaneRecord` carries no direct
    /// alt-screen flag, so a recognized agent (`agentStatus != .unknown`) is
    /// treated as the risky alt-screen case the spike could not fully verify
    /// (large `lines` unproven safe against a recognized agent's synthetic
    /// scroll), and capped to `scroll.viewportRows`; every other pane
    /// (including an unrecognized alt-screen program like a scratch `vim`)
    /// safely takes the full 1000-line request, per the spike's measurement.
    private func fetchBackfillANSI(for pane: PaneRecord, cols: Int, rows: Int) async -> (data: Data, lines: Int)? {
        let viewportRows = pane.scroll?.viewportRows ?? rows
        let isRecognizedAgent = pane.agentStatus != .unknown
        let lines = isRecognizedAgent ? min(1000, viewportRows) : 1000
        let params: [String: JSONValue] = [
            "pane_id": .string(pane.paneID.rawValue),
            "source": .string("recent"),
            "format": .string("ansi"),
            "lines": .int(lines),
        ]
        guard let data = try? await client.requestRaw("pane.read", params),
              let text = Self.extractReadText(data)
        else { return nil }
        return (Data(text.utf8), lines)
    }

    private static func extractReadText(_ data: Data) -> String? {
        struct Result: Decodable { let text: String }
        struct Envelope: Decodable { let result: Result }
        return try? JSONDecoder().decode(Envelope.self, from: data).result.text
    }

    // MARK: - per-pane headless terminal (deep history + pristine-launcher screen check)

    /// The shared headless mirror for `pane`, created once and cached for
    /// its lifetime -- `cols`/`rows` from its first call win; a later resize
    /// does not replace it (deep history's absolute-row math and the
    /// pristine screen check both tolerate the pane's initial size).
    public func paneTerminal(for pane: PaneRecord, cols: Int, rows: Int) -> PaneTerminal {
        if let existing = paneTerminals[pane.paneID] { return existing }
        let terminal = PaneTerminal(
            cols: cols, rows: rows, paneID: pane.paneID, client: client, historyCapability: historyCapabilityGate
        )
        paneTerminals[pane.paneID] = terminal
        return terminal
    }

    // MARK: - typing-lite

    /// The shared `InputRouter` for `pane`, created once and cached for its
    /// lifetime.
    public func inputRouter(for pane: PaneID) -> InputRouter {
        if let existing = inputRouters[pane] { return existing }
        let router = InputRouter(client: client, paneID: pane)
        inputRouters[pane] = router
        return router
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
