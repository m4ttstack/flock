import XCTest
@testable import PaddockCore

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
