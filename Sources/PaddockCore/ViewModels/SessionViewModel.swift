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
    public let frames: AsyncStream<TerminalFrame>
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
    private let client: any HerdrCommandClient
    private let observeAttacher: (any PaneObserveAttaching)?

    public init(client: any HerdrCommandClient, observeAttacher: (any PaneObserveAttaching)? = nil) {
        self.client = client
        self.observeAttacher = observeAttacher
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
    public func beginOrUpdateLiveAttach(pane: PaneRecord, cols: Int, rows: Int) async -> PaneLiveFeed? {
        guard let observeAttacher, cols > 0, rows > 0 else { return nil }
        if let existing = attachedDims[pane.paneID] {
            guard existing != (cols, rows) else { return nil }
            attachedDims[pane.paneID] = (cols, rows)
            await observeAttacher.reattach(pane.paneID, cols: cols, rows: rows)
            return nil
        }
        attachedDims[pane.paneID] = (cols, rows)
        let backfillANSI = await fetchBackfillANSI(for: pane, cols: cols, rows: rows)
        let frames = await observeAttacher.attach(pane.paneID, cols: cols, rows: rows)
        return PaneLiveFeed(backfillANSI: backfillANSI, frames: frames)
    }

    /// Detaches a pane that left the visible set (tab switch, split closed,
    /// window resize dropping it off-screen).
    public func endLiveAttach(pane: PaneID) async {
        guard attachedDims.removeValue(forKey: pane) != nil, let observeAttacher else { return }
        await observeAttacher.detach(pane)
    }

    /// `pane.read {source:"recent", format:"ansi", lines:N}` per spike 4's
    /// backfill recipe. Alt-screen heuristic: `PaneRecord` carries no direct
    /// alt-screen flag, so a recognized agent (`agentStatus != .unknown`) is
    /// treated as the risky alt-screen case the spike could not fully verify
    /// (large `lines` unproven safe against a recognized agent's synthetic
    /// scroll), and capped to `scroll.viewportRows`; every other pane
    /// (including an unrecognized alt-screen program like a scratch `vim`)
    /// safely takes the full 1000-line request, per the spike's measurement.
    private func fetchBackfillANSI(for pane: PaneRecord, cols: Int, rows: Int) async -> Data? {
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
        return Data(text.utf8)
    }

    private static func extractReadText(_ data: Data) -> String? {
        struct Result: Decodable { let text: String }
        struct Envelope: Decodable { let result: Result }
        return try? JSONDecoder().decode(Envelope.self, from: data).result.text
    }
}
