import XCTest
@testable import PaddockCore

final class HerdrOpsTests: XCTestCase {
    private func lastRequest(_ fake: FakeHerdrServer) -> (method: String, params: [String: Any]) {
        let req = fake.receivedRequests.last!
        let dict = (try? JSONSerialization.jsonObject(with: Data(req.paramsJSON.utf8))) as? [String: Any] ?? [:]
        return (req.method, dict)
    }

    // MARK: - pane.move: existing-tab destination

    func testMovePaneToTabSendsExactMethodAndParamsAndDecodesMovedPaneID() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "pane.move", withResultJSON: #"{"move_result":{"pane":{"pane_id":"w2:p9"}}}"#)
        let client = HerdrClient(socketPath: fake.socketPath)

        let result = try await client.perform(.movePaneToTab(
            PaneID(rawValue: "w1:p1"), tab: TabID(rawValue: "w1:t2"), target: PaneID(rawValue: "w1:p5"),
            split: .right, ratio: 0.6
        ))

        let (method, params) = lastRequest(fake)
        XCTAssertEqual(method, "pane.move")
        XCTAssertEqual(params["pane_id"] as? String, "w1:p1")
        let destination = params["destination"] as? [String: Any]
        XCTAssertEqual(destination?["type"] as? String, "tab")
        XCTAssertEqual(destination?["tab_id"] as? String, "w1:t2")
        XCTAssertEqual(destination?["target_pane_id"] as? String, "w1:p5")
        XCTAssertEqual(destination?["split"] as? String, "right")
        XCTAssertEqual(destination?["ratio"] as? Double, 0.6)
        XCTAssertEqual(result.movedPaneNewID, PaneID(rawValue: "w2:p9"))
        XCTAssertNil(result.createdTabID)
        XCTAssertNil(result.createdWorkspaceID)
    }

    /// `target: nil` is the one legitimate omission: it tells herdr to pick
    /// the destination tab's own focused pane (tab-thumbnail drops).
    func testMovePaneToTabWithNilTargetOmitsTargetPaneIDAndRatio() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "pane.move", withResultJSON: #"{"move_result":{"pane":{"pane_id":"w1:p9"}}}"#)
        let client = HerdrClient(socketPath: fake.socketPath)

        _ = try await client.perform(.movePaneToTab(
            PaneID(rawValue: "w1:p1"), tab: TabID(rawValue: "w1:t2"), target: nil, split: .down, ratio: nil
        ))

        let (_, params) = lastRequest(fake)
        let destination = params["destination"] as? [String: Any]
        XCTAssertNil(destination?["target_pane_id"])
        XCTAssertNil(destination?["ratio"])
        XCTAssertEqual(destination?["split"] as? String, "down")
    }

    func testPaneMoveSameTabReasonThrowsSameTab() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "pane.move", withResultJSON: #"{"move_result":{"changed":false,"reason":"same_tab","pane":{"pane_id":"w1:p1"}}}"#)
        let client = HerdrClient(socketPath: fake.socketPath)

        await XCTAssertThrowsErrorAsync(try await client.perform(.movePaneToTab(
            PaneID(rawValue: "w1:p1"), tab: TabID(rawValue: "w1:t1"), target: nil, split: .right, ratio: nil
        ))) {
            XCTAssertEqual($0 as? HerdrOpError, .sameTab)
        }
    }

    func testPaneMoveZoomedTabReasonThrowsZoomedTab() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "pane.move", withResultJSON: #"{"move_result":{"changed":false,"reason":"zoomed_tab","pane":{"pane_id":"w1:p1"}}}"#)
        let client = HerdrClient(socketPath: fake.socketPath)

        await XCTAssertThrowsErrorAsync(try await client.perform(.movePaneToTab(
            PaneID(rawValue: "w1:p1"), tab: TabID(rawValue: "w1:t2"), target: nil, split: .right, ratio: nil
        ))) {
            XCTAssertEqual($0 as? HerdrOpError, .zoomedTab)
        }
    }

    // MARK: - pane.move: new-tab / new-workspace destinations

    func testMovePaneToNewTabSendsWorkspaceAndDecodesCreatedTabID() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "pane.move", withResultJSON: #"{"move_result":{"pane":{"pane_id":"w1:p9"},"created_tab":{"tab_id":"w1:t3"}}}"#)
        let client = HerdrClient(socketPath: fake.socketPath)

        let result = try await client.perform(.movePaneToNewTab(
            PaneID(rawValue: "w1:p1"), workspace: WorkspaceID(rawValue: "w1"), label: "scratch"
        ))

        let (method, params) = lastRequest(fake)
        XCTAssertEqual(method, "pane.move")
        let destination = params["destination"] as? [String: Any]
        XCTAssertEqual(destination?["type"] as? String, "new_tab")
        XCTAssertEqual(destination?["workspace_id"] as? String, "w1")
        XCTAssertEqual(destination?["label"] as? String, "scratch")
        XCTAssertEqual(result.createdTabID, TabID(rawValue: "w1:t3"))
        XCTAssertNil(result.createdWorkspaceID)
    }

    func testMovePaneToNewWorkspaceDecodesCreatedWorkspaceAndTabID() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "pane.move", withResultJSON: #"{"move_result":{"pane":{"pane_id":"w2:p1"},"created_workspace":{"workspace_id":"w2"},"created_tab":{"tab_id":"w2:t1"}}}"#)
        let client = HerdrClient(socketPath: fake.socketPath)

        let result = try await client.perform(.movePaneToNewWorkspace(
            PaneID(rawValue: "w1:p1"), label: "new space", tabLabel: "main"
        ))

        let (_, params) = lastRequest(fake)
        let destination = params["destination"] as? [String: Any]
        XCTAssertEqual(destination?["type"] as? String, "new_workspace")
        XCTAssertEqual(destination?["label"] as? String, "new space")
        XCTAssertEqual(destination?["tab_label"] as? String, "main")
        XCTAssertEqual(result.movedPaneNewID, PaneID(rawValue: "w2:p1"))
        XCTAssertEqual(result.createdWorkspaceID, WorkspaceID(rawValue: "w2"))
        XCTAssertEqual(result.createdTabID, TabID(rawValue: "w2:t1"))
    }

    // MARK: - pane.swap

    func testSwapPanesSendsExactMethodAndParams() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "pane.swap", withResultJSON: #"{"swap":{"reason":null}}"#)
        let client = HerdrClient(socketPath: fake.socketPath)

        let result = try await client.perform(.swapPanes(PaneID(rawValue: "w1:p1"), PaneID(rawValue: "w1:p2")))

        let (method, params) = lastRequest(fake)
        XCTAssertEqual(method, "pane.swap")
        XCTAssertEqual(params["source_pane_id"] as? String, "w1:p1")
        XCTAssertEqual(params["target_pane_id"] as? String, "w1:p2")
        XCTAssertNil(result.movedPaneNewID)
    }

    /// `pane.swap` is same-tab only: source shows the rejection arrives as
    /// `swap.reason == "cross_tab"` on a successful response, not an error
    /// envelope. `perform` throws the same typed error either way.
    func testSwapPanesCrossTabReasonThrowsCrossTab() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "pane.swap", withResultJSON: #"{"swap":{"reason":"cross_tab"}}"#)
        let client = HerdrClient(socketPath: fake.socketPath)

        await XCTAssertThrowsErrorAsync(try await client.perform(.swapPanes(PaneID(rawValue: "w1:p1"), PaneID(rawValue: "w2:p1")))) {
            XCTAssertEqual($0 as? HerdrOpError, .crossTab)
        }
    }

    // MARK: - layout.set_split_ratio

    func testSetSplitRatioSendsExactMethodAndParams() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "layout.set_split_ratio", withResultJSON: "{}")
        let client = HerdrClient(socketPath: fake.socketPath)

        _ = try await client.perform(.setSplitRatio(tab: TabID(rawValue: "w1:t1"), path: [true, false], ratio: 0.35))

        let (method, params) = lastRequest(fake)
        XCTAssertEqual(method, "layout.set_split_ratio")
        XCTAssertEqual(params["tab_id"] as? String, "w1:t1")
        XCTAssertEqual(params["path"] as? [Bool], [true, false])
        XCTAssertEqual(params["ratio"] as? Double ?? 0, 0.35, accuracy: 0.000_001)
    }

    // MARK: - tab.move / workspace.move

    func testMoveTabSendsExactMethodAndParams() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "tab.move", withResultJSON: "{}")
        let client = HerdrClient(socketPath: fake.socketPath)

        _ = try await client.perform(.moveTab(TabID(rawValue: "w1:t2"), insertIndex: 3))

        let (method, params) = lastRequest(fake)
        XCTAssertEqual(method, "tab.move")
        XCTAssertEqual(params["tab_id"] as? String, "w1:t2")
        XCTAssertEqual(params["insert_index"] as? Int, 3)
    }

    func testMoveWorkspaceSendsExactMethodAndParams() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "workspace.move", withResultJSON: "{}")
        let client = HerdrClient(socketPath: fake.socketPath)

        _ = try await client.perform(.moveWorkspace(WorkspaceID(rawValue: "w2"), insertIndex: 1))

        let (method, params) = lastRequest(fake)
        XCTAssertEqual(method, "workspace.move")
        XCTAssertEqual(params["workspace_id"] as? String, "w2")
        XCTAssertEqual(params["insert_index"] as? Int, 1)
    }

    func testMoveWorkspaceBlockSendsTheIDsInOrderAndTheAnchor() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "workspace.move_block", withResultJSON: #"{"type":"workspace_list","workspaces":[]}"#)
        let client = HerdrClient(socketPath: fake.socketPath)

        _ = try await client.perform(.moveWorkspaceBlock(
            [WorkspaceID(rawValue: "w3"), WorkspaceID(rawValue: "w1")], before: WorkspaceID(rawValue: "w2")
        ))

        let (method, params) = lastRequest(fake)
        XCTAssertEqual(method, "workspace.move_block")
        XCTAssertEqual(params["workspace_ids"] as? [String], ["w3", "w1"])
        XCTAssertEqual(params["before_workspace_id"] as? String, "w2")
        XCTAssertEqual(params.count, 2)
    }

    /// herdr's `before_workspace_id` is `#[serde(default)]`: absent means the
    /// end, and a JSON null is not the same wire shape.
    func testMoveWorkspaceBlockWithNoAnchorOmitsIt() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "workspace.move_block", withResultJSON: #"{"type":"workspace_list","workspaces":[]}"#)
        let client = HerdrClient(socketPath: fake.socketPath)

        _ = try await client.perform(.moveWorkspaceBlock([WorkspaceID(rawValue: "w1")], before: nil))

        let request = try XCTUnwrap(fake.receivedRequests.last)
        XCTAssertFalse(request.paramsJSON.contains("before_workspace_id"), request.paramsJSON)
        XCTAssertEqual(lastRequest(fake).params["workspace_ids"] as? [String], ["w1"])
    }

    func testMoveWorkspaceBlockFailureSurfacesItsCode() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.failNext(method: "workspace.move_block", code: "workspace_move_block_failed", message: "before_workspace_id must not be part of workspace_ids")
        let client = HerdrClient(socketPath: fake.socketPath)

        await XCTAssertThrowsErrorAsync(try await client.perform(.moveWorkspaceBlock([WorkspaceID(rawValue: "w1")], before: WorkspaceID(rawValue: "w1")))) {
            XCTAssertEqual($0 as? HerdrOpError, .other(code: "workspace_move_block_failed", message: "before_workspace_id must not be part of workspace_ids"))
        }
    }

    // MARK: - rename

    func testRenamePaneNilLabelClears() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "pane.rename", withResultJSON: "{}")
        let client = HerdrClient(socketPath: fake.socketPath)

        _ = try await client.perform(.renamePane(PaneID(rawValue: "w1:p1"), nil))

        let (method, params) = lastRequest(fake)
        XCTAssertEqual(method, "pane.rename")
        XCTAssertEqual(params["pane_id"] as? String, "w1:p1")
        XCTAssertNil(params["label"], "a nil label must not be sent as a non-null value")
    }

    func testRenamePaneSendsLabel() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "pane.rename", withResultJSON: "{}")
        let client = HerdrClient(socketPath: fake.socketPath)

        _ = try await client.perform(.renamePane(PaneID(rawValue: "w1:p1"), "scratch"))

        let (_, params) = lastRequest(fake)
        XCTAssertEqual(params["label"] as? String, "scratch")
    }

    func testRenameTabSendsExactMethodAndParams() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "tab.rename", withResultJSON: "{}")
        let client = HerdrClient(socketPath: fake.socketPath)

        _ = try await client.perform(.renameTab(TabID(rawValue: "w1:t1"), "builds"))

        let (method, params) = lastRequest(fake)
        XCTAssertEqual(method, "tab.rename")
        XCTAssertEqual(params["tab_id"] as? String, "w1:t1")
        XCTAssertEqual(params["label"] as? String, "builds")
    }

    func testRenameWorkspaceSendsExactMethodAndParams() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "workspace.rename", withResultJSON: "{}")
        let client = HerdrClient(socketPath: fake.socketPath)

        _ = try await client.perform(.renameWorkspace(WorkspaceID(rawValue: "w1"), "repo-tools"))

        let (method, params) = lastRequest(fake)
        XCTAssertEqual(method, "workspace.rename")
        XCTAssertEqual(params["workspace_id"] as? String, "w1")
        XCTAssertEqual(params["label"] as? String, "repo-tools")
    }

    // MARK: - close

    func testClosePaneSendsExactMethodAndParams() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "pane.close", withResultJSON: "{}")
        let client = HerdrClient(socketPath: fake.socketPath)

        _ = try await client.perform(.closePane(PaneID(rawValue: "w1:p1")))

        let (method, params) = lastRequest(fake)
        XCTAssertEqual(method, "pane.close")
        XCTAssertEqual(params["pane_id"] as? String, "w1:p1")
    }

    func testCloseTabSendsExactMethodAndParams() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "tab.close", withResultJSON: "{}")
        let client = HerdrClient(socketPath: fake.socketPath)

        _ = try await client.perform(.closeTab(TabID(rawValue: "w1:t1")))

        let (method, params) = lastRequest(fake)
        XCTAssertEqual(method, "tab.close")
        XCTAssertEqual(params["tab_id"] as? String, "w1:t1")
    }

    func testCloseWorkspaceSendsCloseGroupFlag() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "workspace.close", withResultJSON: "{}")
        let client = HerdrClient(socketPath: fake.socketPath)

        _ = try await client.perform(.closeWorkspace(WorkspaceID(rawValue: "w1"), closeGroup: true))

        let (method, params) = lastRequest(fake)
        XCTAssertEqual(method, "workspace.close")
        XCTAssertEqual(params["workspace_id"] as? String, "w1")
        XCTAssertEqual(params["close_group"] as? Bool, true)
    }

    /// The one hard constraint that really is an `ErrorResponse` (unlike
    /// `same_tab`/`cross_tab`/`zoomed_tab`, which arrive as a `reason` on a
    /// success response, per the pane.move/pane.swap tests above).
    func testCloseWorkspaceGroupRequiredErrorThrowsTyped() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.failNext(method: "workspace.close", code: "workspace_group_close_required", message: "use close_group")
        let client = HerdrClient(socketPath: fake.socketPath)

        await XCTAssertThrowsErrorAsync(try await client.perform(.closeWorkspace(WorkspaceID(rawValue: "w1"), closeGroup: false))) {
            XCTAssertEqual($0 as? HerdrOpError, .workspaceGroupCloseRequired)
        }
    }

    func testUnknownErrorCodeFallsBackToOther() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.failNext(method: "pane.close", code: "pane_not_found", message: "no such pane")
        let client = HerdrClient(socketPath: fake.socketPath)

        await XCTAssertThrowsErrorAsync(try await client.perform(.closePane(PaneID(rawValue: "w1:p9")))) {
            XCTAssertEqual($0 as? HerdrOpError, .other(code: "pane_not_found", message: "no such pane"))
        }
    }

    // MARK: - zoom

    func testZoomSendsExactMethodAndParams() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "pane.zoom", withResultJSON: "{}")
        let client = HerdrClient(socketPath: fake.socketPath)

        _ = try await client.perform(.zoom(PaneID(rawValue: "w1:p1"), mode: .toggle))

        let (method, params) = lastRequest(fake)
        XCTAssertEqual(method, "pane.zoom")
        XCTAssertEqual(params["pane_id"] as? String, "w1:p1")
        XCTAssertEqual(params["mode"] as? String, "toggle")
    }

    // MARK: - focus

    func testFocusPaneSendsExactMethodAndParams() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "pane.focus", withResultJSON: "{}")
        let client = HerdrClient(socketPath: fake.socketPath)

        _ = try await client.perform(.focusPane(PaneID(rawValue: "w1:p1")))

        let (method, params) = lastRequest(fake)
        XCTAssertEqual(method, "pane.focus")
        XCTAssertEqual(params["pane_id"] as? String, "w1:p1")
    }

    func testFocusTabSendsExactMethodAndParams() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "tab.focus", withResultJSON: "{}")
        let client = HerdrClient(socketPath: fake.socketPath)

        _ = try await client.perform(.focusTab(TabID(rawValue: "w1:t1")))

        let (method, params) = lastRequest(fake)
        XCTAssertEqual(method, "tab.focus")
        XCTAssertEqual(params["tab_id"] as? String, "w1:t1")
    }

    func testFocusWorkspaceSendsExactMethodAndParams() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "workspace.focus", withResultJSON: "{}")
        let client = HerdrClient(socketPath: fake.socketPath)

        _ = try await client.perform(.focusWorkspace(WorkspaceID(rawValue: "w1")))

        let (method, params) = lastRequest(fake)
        XCTAssertEqual(method, "workspace.focus")
        XCTAssertEqual(params["workspace_id"] as? String, "w1")
    }

    // MARK: - explicit ids, never omitted

    /// Sweeps every op family (`movePaneToTab`'s legitimate `target: nil` is
    /// covered separately above) asserting the id(s) each op's wire method
    /// requires are always present and non-empty, so a future case can't
    /// silently regress into relying on herdr's own focused-pane fallback.
    func testEveryOpSendsItsExplicitIDs() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        for method in [
            "pane.move", "pane.swap", "layout.set_split_ratio", "tab.move", "workspace.move", "workspace.move_block",
            "pane.rename", "tab.rename", "workspace.rename", "pane.close", "tab.close",
            "workspace.close", "pane.zoom", "pane.focus", "tab.focus", "workspace.focus",
        ] {
            fake.respond(to: method, withResultJSON: #"{"move_result":{"pane":{"pane_id":"w1:p1"}},"swap":{"reason":null}}"#)
        }
        let client = HerdrClient(socketPath: fake.socketPath)

        let ops: [PrimitiveOp] = [
            .movePaneToTab(PaneID(rawValue: "w1:p1"), tab: TabID(rawValue: "w1:t2"), target: nil, split: .right, ratio: nil),
            .movePaneToNewTab(PaneID(rawValue: "w1:p1"), workspace: WorkspaceID(rawValue: "w1"), label: nil),
            .movePaneToNewWorkspace(PaneID(rawValue: "w1:p1"), label: nil, tabLabel: nil),
            .swapPanes(PaneID(rawValue: "w1:p1"), PaneID(rawValue: "w1:p2")),
            .setSplitRatio(tab: TabID(rawValue: "w1:t1"), path: [true], ratio: 0.5),
            .moveTab(TabID(rawValue: "w1:t1"), insertIndex: 0),
            .moveWorkspace(WorkspaceID(rawValue: "w1"), insertIndex: 0),
            .moveWorkspaceBlock([WorkspaceID(rawValue: "w1")], before: nil),
            .renamePane(PaneID(rawValue: "w1:p1"), nil),
            .renameTab(TabID(rawValue: "w1:t1"), "x"),
            .renameWorkspace(WorkspaceID(rawValue: "w1"), "x"),
            .closePane(PaneID(rawValue: "w1:p1")),
            .closeTab(TabID(rawValue: "w1:t1")),
            .closeWorkspace(WorkspaceID(rawValue: "w1"), closeGroup: false),
            .zoom(PaneID(rawValue: "w1:p1"), mode: .toggle),
            .focusPane(PaneID(rawValue: "w1:p1")),
            .focusTab(TabID(rawValue: "w1:t1")),
            .focusWorkspace(WorkspaceID(rawValue: "w1")),
        ]

        for op in ops {
            _ = try await client.perform(op)
        }

        XCTAssertEqual(fake.receivedRequests.count, ops.count)
        for request in fake.receivedRequests {
            let dict = (try? JSONSerialization.jsonObject(with: Data(request.paramsJSON.utf8))) as? [String: Any] ?? [:]
            switch request.method {
            case "pane.move":
                XCTAssertFalse((dict["pane_id"] as? String ?? "").isEmpty, request.method)
                XCTAssertNotNil(dict["destination"] as? [String: Any], request.method)
            case "pane.swap":
                XCTAssertFalse((dict["source_pane_id"] as? String ?? "").isEmpty, request.method)
                XCTAssertFalse((dict["target_pane_id"] as? String ?? "").isEmpty, request.method)
            case "layout.set_split_ratio", "tab.move", "tab.rename", "tab.close", "tab.focus":
                XCTAssertFalse((dict["tab_id"] as? String ?? "").isEmpty, request.method)
            case "workspace.move", "workspace.rename", "workspace.close", "workspace.focus":
                XCTAssertFalse((dict["workspace_id"] as? String ?? "").isEmpty, request.method)
            case "workspace.move_block":
                XCTAssertFalse((dict["workspace_ids"] as? [String] ?? []).isEmpty, request.method)
            case "pane.rename", "pane.close", "pane.focus", "pane.zoom":
                XCTAssertFalse((dict["pane_id"] as? String ?? "").isEmpty, request.method)
            default:
                XCTFail("unexpected method \(request.method)")
            }
        }
    }
}
