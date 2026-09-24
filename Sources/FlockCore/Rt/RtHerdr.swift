import Foundation

/// The herdr verbs rt's hidden terminals use, with their wire shapes in one
/// place. Everything is created unfocused: herdr's focus moving into a hidden
/// workspace would take the canvas with it.
public struct RtHerdr: Sendable {
    public struct Created: Equatable, Sendable {
        public let workspaceID: WorkspaceID
        public let tabID: TabID
        public let rootPaneID: PaneID

        public init(workspaceID: WorkspaceID, tabID: TabID, rootPaneID: PaneID) {
            self.workspaceID = workspaceID
            self.tabID = tabID
            self.rootPaneID = rootPaneID
        }
    }

    struct Unreadable: Error {}

    let client: any HerdrCommandClient

    public init(client: any HerdrCommandClient) {
        self.client = client
    }

    public func createWorkspace(label: String, cwd: String, env: [String: String]) async throws -> Created {
        try Self.created(from: await client.requestRaw("workspace.create", [
            "label": .string(label), "cwd": .string(cwd), "focus": .bool(false), "env": Self.object(env),
        ]))
    }

    public func createTab(in workspace: WorkspaceID, label: String, cwd: String, env: [String: String]) async throws -> Created {
        try Self.created(from: await client.requestRaw("tab.create", [
            "workspace_id": .string(workspace.rawValue), "label": .string(label), "cwd": .string(cwd),
            "focus": .bool(false), "env": Self.object(env),
        ]))
    }

    public func renameTab(_ tab: TabID, to label: String) async throws {
        _ = try await client.requestRaw("tab.rename", ["tab_id": .string(tab.rawValue), "label": .string(label)])
    }

    /// The Enter rides `keys`: herdr pastes `text` inside a bracketed paste
    /// whenever the program enabled one, and a newline there is not a submit.
    public func type(_ line: String, into pane: PaneID) async throws {
        _ = try await client.requestRaw("pane.send_input", [
            "pane_id": .string(pane.rawValue), "text": .string(line), "keys": .array([.string("Enter")]),
        ])
    }

    /// Keys, never text: a `y` sent as text reaches a program with bracketed
    /// paste on as a paste, which a confirm does not read as a keypress.
    public func sendKeys(_ keys: [String], to pane: PaneID) async throws {
        _ = try await client.requestRaw("pane.send_keys", [
            "pane_id": .string(pane.rawValue), "keys": .array(keys.map(JSONValue.string)),
        ])
    }

    public func paneState(_ pane: PaneID) async -> PaneForegroundJob.Snapshot? {
        guard let data = try? await client.requestRaw("pane.process_info", ["pane_id": .string(pane.rawValue)]) else {
            return nil
        }
        return PaneForegroundJob.snapshot(processInfoResponse: data)
    }

    public func closeTab(_ tab: TabID) async throws {
        _ = try await client.requestRaw("tab.close", ["tab_id": .string(tab.rawValue)])
    }

    public func closeWorkspace(_ workspace: WorkspaceID) async throws {
        _ = try await client.requestRaw("workspace.close", ["workspace_id": .string(workspace.rawValue)])
    }

    public func focus(_ pane: PaneID) async throws {
        _ = try await client.requestRaw("pane.focus", ["pane_id": .string(pane.rawValue)])
    }

    public func split(_ pane: PaneID, cwd: String) async throws {
        _ = try await client.requestRaw("pane.split", [
            "target_pane_id": .string(pane.rawValue), "direction": .string("right"),
            "cwd": .string(cwd), "focus": .bool(true),
        ])
    }

    public static func describe(_ error: Error) -> String {
        guard let clientError = error as? HerdrClientError else { return String(describing: error) }
        switch clientError {
        case let .server(code, message): return message.isEmpty ? code : message
        case let .transport(message): return message
        case let .timedOut(method): return "\(method) got no answer from herdr"
        case let .protocolTooOld(found, required): return "protocol \(found), need \(required)"
        }
    }

    private static func object(_ env: [String: String]) -> JSONValue {
        .object(env.mapValues(JSONValue.string))
    }

    private static func created(from data: Data) throws -> Created {
        struct Tab: Decodable {
            let tabID: TabID
            let workspaceID: WorkspaceID
            enum CodingKeys: String, CodingKey {
                case tabID = "tab_id"
                case workspaceID = "workspace_id"
            }
        }
        struct Pane: Decodable {
            let paneID: PaneID
            enum CodingKeys: String, CodingKey { case paneID = "pane_id" }
        }
        struct Result: Decodable {
            let tab: Tab
            let rootPane: Pane
            enum CodingKeys: String, CodingKey {
                case tab
                case rootPane = "root_pane"
            }
        }
        struct Envelope: Decodable { let result: Result }
        guard let result = try? JSONDecoder().decode(Envelope.self, from: data).result else { throw Unreadable() }
        return Created(workspaceID: result.tab.workspaceID, tabID: result.tab.tabID, rootPaneID: result.rootPane.paneID)
    }
}
