import XCTest
@testable import FlockCore

final class HerdrModelTests: XCTestCase {
    func testSnapshotFixtureDecodes() throws {
        let data = try fixture("snapshot.json")
        let snap = try HerdrDecoder.snapshot(fromResponseLine: data)
        XCTAssertGreaterThan(snap.workspaces.count, 0)
        XCTAssertEqual(snap.layouts.first?.panes.isEmpty, false)
        XCTAssertGreaterThanOrEqual(snap.protocolVersion, 19)
    }

    func testEventFixtureLinesDecode() throws {
        for line in try fixtureLines("events.ndjson") {
            XCTAssertNoThrow(try HerdrDecoder.event(fromLine: line))
        }
    }

    func testAPaneRecordCarriesItsForegroundFolderWhenHerdrSendsOne() throws {
        let with = #"{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1","focused":true,"agent_status":"idle","revision":0,"cwd":"/src/tools","foreground_cwd":"/src/acme"}"#
        let without = #"{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1","focused":true,"agent_status":"idle","revision":0,"cwd":"/src/tools"}"#

        XCTAssertEqual(try JSONDecoder().decode(PaneRecord.self, from: Data(with.utf8)).foregroundCwd, "/src/acme")
        XCTAssertNil(try JSONDecoder().decode(PaneRecord.self, from: Data(without.utf8)).foregroundCwd)
    }

    func testAPaneRecordCarriesTheAgentHerdrDetectedInIt() throws {
        let claude = #"{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1","focused":true,"agent_status":"idle","revision":1,"cwd":"/src/acme","agent":"claude"}"#
        let shell = #"{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1","focused":true,"agent_status":"unknown","revision":0,"cwd":"/src/acme"}"#

        XCTAssertEqual(try JSONDecoder().decode(PaneRecord.self, from: Data(claude.utf8)).agent, "claude")
        XCTAssertNil(try JSONDecoder().decode(PaneRecord.self, from: Data(shell.utf8)).agent)
    }

    func testUnknownEventTypeIsTolerated() throws {
        let ev = try HerdrDecoder.event(fromLine: Data(#"{"data":{"type":"pane.hologram","x":1}}"#.utf8))
        guard case .unknown(let t) = ev else { return XCTFail() }
        XCTAssertEqual(t, "pane.hologram")
    }

    /// The per-pane `pane.scroll_changed` subscription frame is not an
    /// `EventEnvelope` (`data` has no `type`), so it has its own decoder;
    /// shape per herdr's `SubscriptionEventEnvelope`/`PaneScrollChangedEvent`.
    func testScrollChangedSubscriptionLineDecodes() throws {
        let line = Data(#"{"event":"pane.scroll_changed","data":{"pane_id":"w1:p2","workspace_id":"w1","scroll":{"offset_from_bottom":4,"max_offset_from_bottom":17442,"viewport_rows":56}}}"#.utf8)

        let decoded = try XCTUnwrap(HerdrDecoder.scrollChanged(fromLine: line))

        XCTAssertEqual(decoded.paneID, PaneID(rawValue: "w1:p2"))
        XCTAssertEqual(decoded.scroll, ScrollInfo(offsetFromBottom: 4, maxOffsetFromBottom: 17442, viewportRows: 56))
    }

    func testScrollChangedDecoderIgnoresAcksAndOtherEvents() throws {
        XCTAssertNil(HerdrDecoder.scrollChanged(fromLine: Data(#"{"id":"s","result":{"type":"subscription_started"}}"#.utf8)))
        XCTAssertNil(HerdrDecoder.scrollChanged(fromLine: Data(#"{"event":"pane.agent_status_changed","data":{"pane_id":"w1:p2","workspace_id":"w1","agent_status":"idle"}}"#.utf8)))
        XCTAssertNil(HerdrDecoder.scrollChanged(fromLine: Data("{not json".utf8)))
    }

    /// herdr's own `TabMoved` carries `tabs` unconditionally (no
    /// `skip_serializing_if`), so a frame without it is not one herdr sends.
    /// Decoding it as an empty list would hand the reducer a wholesale
    /// assignment that empties that workspace's tab strip until the next
    /// snapshot; `.unknown` leaves the strip alone and matches no convergence
    /// watch, so a plan waiting on the move resnapshots instead.
    func testTabMovedWithoutItsTabListDecodesAsUnknown() throws {
        let ev = try HerdrDecoder.event(
            fromLine: Data(#"{"data":{"type":"tab_moved","tab_id":"w1:t1","workspace_id":"w2","insert_index":0}}"#.utf8))

        guard case .unknown(let type) = ev else { return XCTFail("expected .unknown, got \(ev)") }
        XCTAssertEqual(type, "tab_moved")
    }

    func testTabMovedCarryingItsTabListStillDecodes() throws {
        let ev = try HerdrDecoder.event(fromLine: Data(#"""
        {"data":{"type":"tab_moved","tab_id":"w1:t1","workspace_id":"w2","insert_index":0,"tabs":[{"tab_id":"w1:t1","workspace_id":"w2","label":"t1","number":1,"pane_count":1,"agent_status":"unknown"}]}}
        """#.utf8))

        guard case .tabMoved(let tabID, let workspaceID, let tabs) = ev else { return XCTFail("expected .tabMoved, got \(ev)") }
        XCTAssertEqual(tabID, TabID(rawValue: "w1:t1"))
        XCTAssertEqual(workspaceID, WorkspaceID(rawValue: "w2"))
        XCTAssertEqual(tabs.map(\.tabID), [TabID(rawValue: "w1:t1")])
    }

    /// The rail's own half of the case above: `WorkspaceMoved` and
    /// `WorkspaceReordered` both carry `workspaces` unconditionally, and an
    /// empty list assigned wholesale is the entire rail gone.
    func testWorkspaceMoveAndReorderWithoutTheirWorkspaceListDecodeAsUnknown() throws {
        let moved = try HerdrDecoder.event(
            fromLine: Data(#"{"data":{"type":"workspace_moved","workspace_id":"w1","insert_index":2}}"#.utf8))
        let reordered = try HerdrDecoder.event(
            fromLine: Data(#"{"data":{"type":"workspace_reordered","workspace_ids":["w1"],"before_workspace_id":"w2"}}"#.utf8))

        guard case .unknown(let movedType) = moved else { return XCTFail("expected .unknown, got \(moved)") }
        guard case .unknown(let reorderedType) = reordered else { return XCTFail("expected .unknown, got \(reordered)") }
        XCTAssertEqual(movedType, "workspace_moved")
        XCTAssertEqual(reorderedType, "workspace_reordered")
    }

    func testWorkspaceReorderedCarryingItsWorkspaceListStillDecodes() throws {
        let ev = try HerdrDecoder.event(fromLine: Data(#"""
        {"data":{"type":"workspace_reordered","workspace_ids":["w2"],"workspaces":[{"workspace_id":"w2","label":"w2","number":1,"active_tab_id":"w2:t1","agent_status":"unknown"},{"workspace_id":"w1","label":"w1","number":2,"active_tab_id":"w1:t1","agent_status":"unknown"}]}}
        """#.utf8))

        guard case .workspaceReordered(let workspaces) = ev else { return XCTFail("expected .workspaceReordered, got \(ev)") }
        XCTAssertEqual(workspaces.map(\.workspaceID), [WorkspaceID(rawValue: "w2"), WorkspaceID(rawValue: "w1")])
    }

    /// Payload captured from a live `layout.export` round trip against herdr
    /// 0.9.0 (a two-pane right split), pinning the decoder to the real wire
    /// shape rather than an assumed one.
    func testExportedLayoutDescriptionDecodesLiveWireShape() throws {
        let json = Data(#"""
        {"workspace_id":"w1","tab_id":"w1:t1","zoomed":false,"focused_pane_id":"w1:p1","root":{"type":"split","direction":"right","ratio":0.5,"first":{"type":"pane","pane_id":"w1:p1","cwd":"/private/tmp"},"second":{"type":"pane","pane_id":"w1:p2","cwd":"/private/tmp"}}}
        """#.utf8)

        let description = try JSONDecoder().decode(ExportedLayoutDescription.self, from: json)

        XCTAssertEqual(description.tabID, TabID(rawValue: "w1:t1"))
        XCTAssertEqual(description.focusedPaneID, PaneID(rawValue: "w1:p1"))
        guard case .split(let direction, let ratio, let first, let second) = description.root else {
            return XCTFail("expected split root")
        }
        XCTAssertEqual(direction, .right)
        XCTAssertEqual(ratio, 0.5, accuracy: 0.0001)
        guard case .pane(let firstPane) = first, case .pane(let secondPane) = second else {
            return XCTFail("expected pane leaves")
        }
        XCTAssertEqual(firstPane.paneID, PaneID(rawValue: "w1:p1"))
        XCTAssertEqual(secondPane.paneID, PaneID(rawValue: "w1:p2"))
    }

    func testExportedLayoutNodeUnrecognizedTypeThrowsRatherThanCrashing() {
        let json = Data(#"{"type":"portal"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(ExportedLayoutNode.self, from: json))
    }
}
