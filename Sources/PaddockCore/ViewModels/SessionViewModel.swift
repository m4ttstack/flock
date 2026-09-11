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
    public private(set) var lastLines: [PaneID: String] = [:]

    private var lastLineRevisions: [PaneID: Int] = [:]
    private let client: any HerdrCommandClient

    public init(client: any HerdrCommandClient) {
        self.client = client
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

    public func jumpToHerdr(pane id: PaneID) async {
        await send("pane.focus", ["pane_id": .string(id.rawValue)])
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
}
