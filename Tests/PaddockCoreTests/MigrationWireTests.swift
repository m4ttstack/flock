import XCTest
@testable import PaddockCore

/// The two-pane tab migration end to end against herdr's OWN recorded
/// response, rather than the minimal fixture the rest of the engine tests
/// use: the ids step 1 needs (the created tab, the re-keyed anchor pane)
/// arrive buried in a reply that also carries two whole layouts, and a
/// decode that quietly lost either of them would leave the first pane moved
/// and the second stranded -- a half-migrated tab, with the tab itself still
/// in the workspace it was dragged out of.
///
/// Both payloads below are verbatim from a live herdr 0.9.0 (protocol 22)
/// scratch session performing exactly this pair of moves.
final class MigrationWireTests: XCTestCase {
    private static let recordedStepZero = #"{"type":"pane_move","move_result":{"changed":true,"previous_pane_id":"w1:p1","previous_workspace_id":"w1","previous_tab_id":"w1:t1","pane":{"pane_id":"w2:p2","terminal_id":"term_65badb213ff631","workspace_id":"w2","tab_id":"w2:t2","focused":false,"cwd":"/private/tmp","foreground_cwd":"/private/tmp","agent_status":"unknown","scroll":{"offset_from_bottom":0,"max_offset_from_bottom":0,"viewport_rows":40},"revision":0},"source_layout":{"workspace_id":"w1","tab_id":"w1:t1","zoomed":false,"area":{"x":0,"y":0,"width":120,"height":40},"focused_pane_id":"w1:p2","panes":[{"pane_id":"w1:p2","focused":true,"rect":{"x":0,"y":0,"width":120,"height":40}}],"splits":[]},"target_layout":{"workspace_id":"w2","tab_id":"w2:t2","zoomed":false,"area":{"x":0,"y":0,"width":120,"height":40},"focused_pane_id":"w2:p2","panes":[{"pane_id":"w2:p2","focused":true,"rect":{"x":0,"y":0,"width":120,"height":40}}],"splits":[]},"created_tab":{"tab_id":"w2:t2","workspace_id":"w2","number":2,"label":"2","focused":false,"pane_count":1,"agent_status":"unknown"},"focused_pane_id":"w2:p2"}}"#

    private static let recordedStepOne = #"{"type":"pane_move","move_result":{"changed":true,"previous_pane_id":"w1:p2","previous_workspace_id":"w1","previous_tab_id":"w1:t1","pane":{"pane_id":"w2:p3","terminal_id":"term_65badb2147a1c2","workspace_id":"w2","tab_id":"w2:t2","focused":false,"cwd":"/private/tmp","foreground_cwd":"/private/tmp","agent_status":"unknown","scroll":{"offset_from_bottom":0,"max_offset_from_bottom":0,"viewport_rows":40},"revision":0},"target_layout":{"workspace_id":"w2","tab_id":"w2:t2","zoomed":false,"area":{"x":0,"y":0,"width":120,"height":40},"focused_pane_id":"w2:p2","panes":[{"pane_id":"w2:p2","focused":true,"rect":{"x":0,"y":0,"width":60,"height":40}},{"pane_id":"w2:p3","focused":false,"rect":{"x":60,"y":0,"width":60,"height":40}}],"splits":[{"id":"split_0_root","direction":"right","ratio":0.5,"rect":{"x":0,"y":0,"width":120,"height":40}}]},"focused_pane_id":"w2:p2"}}"#

    func testBothMovesReachTheWireWithTheIdsHerdrsOwnReplyCarried() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respondSequence(to: "pane.move", withResultJSONs: [Self.recordedStepZero, Self.recordedStepOne])
        fake.respond(to: "pane.focus", withResultJSON: #"{"ok":true}"#)
        let engine = MutationEngine(client: HerdrClient(socketPath: fake.socketPath))
        let seedModel = Self.seedModel()

        guard case let .success(forward) = plan(
            dragging: .tab(TabID(rawValue: "w1:t1")), onto: .workspaceThumbnail(WorkspaceID(rawValue: "w2")), model: seedModel
        ) else {
            XCTFail("the planner refused a two-pane tab onto another workspace")
            return
        }
        XCTAssertEqual(forward.ops.count, 2, "a two-pane tab migrates as an anchor move plus one split-in per remaining pane")

        let result = await engine.execute(forward, model: seedModel)
        if case let .failure(failure) = result {
            XCTFail("the migration failed at \(failure.failedOp): \(failure.code) \(failure.message)")
            return
        }

        let moves = fake.receivedRequests.filter { $0.method == "pane.move" }
        XCTAssertEqual(moves.count, 2, "only \(moves.count) of the plan's two moves reached herdr")
        guard moves.count == 2 else { return }

        let anchor = try Self.params(moves[0])
        XCTAssertEqual(anchor["pane_id"] as? String, "w1:p1")
        XCTAssertEqual((anchor["destination"] as? [String: Any])?["type"] as? String, "new_tab")

        // The point of the case: step 1's tab and target are placeholders
        // until step 0 answers, and what goes out has to be the ids that
        // answer carried, not the sentinels.
        let second = try Self.params(moves[1])
        XCTAssertEqual(second["pane_id"] as? String, "w1:p2")
        let destination = try XCTUnwrap(second["destination"] as? [String: Any])
        XCTAssertEqual(destination["type"] as? String, "tab")
        XCTAssertEqual(destination["tab_id"] as? String, "w2:t2", "step 1 did not take the tab step 0's created_tab named")
        XCTAssertEqual(destination["target_pane_id"] as? String, "w2:p2", "step 1 did not take the re-keyed anchor step 0 returned")
        XCTAssertEqual(destination["split"] as? String, "right")
    }

    private static func params(_ request: (method: String, paramsJSON: String)) throws -> [String: Any] {
        let data = try XCTUnwrap(request.paramsJSON.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// The e2e seed as herdr reports it: one workspace with a tab split
    /// right at 0.5, and a second workspace to migrate into.
    private static func seedModel() -> SessionModel {
        func pane(_ id: String, focused: Bool = false) -> PaneRecord {
            PaneRecord(
                paneID: PaneID(rawValue: id), workspaceID: WorkspaceID(rawValue: "w1"), tabID: TabID(rawValue: "w1:t1"),
                focused: focused, agentStatus: .idle, revision: 0, terminalTitleStripped: nil, label: nil,
                cwd: "/tmp", scroll: nil
            )
        }
        return SessionModel(snapshot: SessionSnapshot(
            version: "0.9.0", protocolVersion: 22,
            focusedWorkspaceID: WorkspaceID(rawValue: "w1"), focusedTabID: TabID(rawValue: "w1:t1"),
            focusedPaneID: PaneID(rawValue: "w1:p1"),
            workspaces: [
                WorkspaceRecord(workspaceID: WorkspaceID(rawValue: "w1"), label: "seed", number: 1, activeTabID: TabID(rawValue: "w1:t1"), agentStatus: .idle),
                WorkspaceRecord(workspaceID: WorkspaceID(rawValue: "w2"), label: "other", number: 2, activeTabID: TabID(rawValue: "w2:t1"), agentStatus: .idle),
            ],
            tabs: [TabRecord(tabID: TabID(rawValue: "w1:t1"), workspaceID: WorkspaceID(rawValue: "w1"), label: "1", number: 1, paneCount: 2, agentStatus: .idle)],
            panes: [pane("w1:p1", focused: true), pane("w1:p2")],
            layouts: [LayoutSnapshot(
                workspaceID: WorkspaceID(rawValue: "w1"), tabID: TabID(rawValue: "w1:t1"), zoomed: false,
                area: CellRect(x: 0, y: 0, width: 120, height: 40), focusedPaneID: PaneID(rawValue: "w1:p1"),
                panes: [
                    PaneRect(paneID: PaneID(rawValue: "w1:p1"), focused: true, rect: CellRect(x: 0, y: 0, width: 60, height: 40)),
                    PaneRect(paneID: PaneID(rawValue: "w1:p2"), focused: false, rect: CellRect(x: 60, y: 0, width: 60, height: 40)),
                ],
                splits: [SplitInfo(id: "split_0_root", direction: .right, ratio: 0.5, rect: CellRect(x: 0, y: 0, width: 120, height: 40))]
            )]
        ))
    }
}
