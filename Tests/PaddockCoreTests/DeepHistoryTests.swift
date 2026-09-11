import XCTest
@testable import PaddockCore

/// Deep history via `pane.selection.read`. Wire shapes here are
/// verified against herdr's real schema (`src/api/schema/panes.rs`,
/// `src/api/schema/response.rs`) and pinned by `HerdrClientTests`'
/// `pane.get` fixture (`{"type":"pane_info","pane":{...}}`); `pane.selection`
/// results are flat (`{"type":"pane_selection","pane_id":...,"text":...}`,
/// no wrapper key), unlike `pane.read`'s `"read"` wrapper.
final class DeepHistoryTests: XCTestCase {
    private static let paneGet1000Rows =
        #"{"type":"pane_info","pane":{"revision":5,"scroll":{"max_offset_from_bottom":800,"viewport_rows":200}}}"#

    private func selectionResult(_ text: String) -> String {
        #"{"type":"pane_selection","pane_id":"w1:p1","text":"\#(text)"}"#
    }

    private func makeTerminal(
        server: FakeHerdrServer, cols: Int = 80, gate: HistoryCapabilityGate = HistoryCapabilityGate()
    ) -> PaneTerminal {
        PaneTerminal(
            cols: cols, rows: 24,
            paneID: PaneID(rawValue: "w1:p1"),
            client: HerdrClient(socketPath: server.socketPath),
            historyCapability: gate
        )
    }

    private func selectionReadParams(_ paramsJSON: String) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(paramsJSON.utf8)) as? [String: Any])
    }

    // MARK: - contiguous anchor (no gap against the already-shown backfill)

    /// Reported live: a dimmed band of loaded history followed by an abrupt,
    /// uncommunicated jump straight into the live buffer's own top, with the
    /// rows in between never shown or accounted for anywhere. Root cause:
    /// `oldestFetchedRow` was seeded from the pane's TOTAL row count, not
    /// from the row directly above what backfill already displays -- so the
    /// first `loadOlderHistory` chunk started well short of the live
    /// buffer's actual top, skipping every row backfill already covers.
    func testFirstChunkAnchorsContiguouslyAboveTheBackfilledLiveBuffer() async throws {
        let server = FakeHerdrServer(); try server.start(); defer { server.stop() }
        server.respond(to: "pane.get", withResultJSON: Self.paneGet1000Rows)
        server.respond(to: "pane.selection.read", withResultJSON: selectionResult("OLDER"))
        let term = makeTerminal(server: server)
        // Backfill covers the last 800 of the pane's 1000 total rows (rows
        // 200-999); the live buffer's own top sits at absolute row 200.
        term.seedBackfill(ansi: Data(String(repeating: "x\n", count: 800).utf8), lineCount: 800)

        _ = try await term.loadOlderHistory(chunkRows: 200)

        let request = try XCTUnwrap(server.receivedRequests.last { $0.method == "pane.selection.read" })
        let params = try selectionReadParams(request.paramsJSON)
        XCTAssertEqual((params["cursor"] as? [String: Any])?["row"] as? Int, 199, "must end exactly where the live buffer's top begins, not overlap it")
        XCTAssertEqual((params["anchor"] as? [String: Any])?["row"] as? Int, 0)
    }

    // MARK: - sequential chunks + oldest-first accumulation

    func testSequentialChunksRequestDecreasingAbsoluteRowRangesAndAccumulateOldestFirst() async throws {
        let server = FakeHerdrServer(); try server.start(); defer { server.stop() }
        server.respond(to: "pane.get", withResultJSON: Self.paneGet1000Rows)
        server.respond(to: "pane.selection.read", withResultJSON: selectionResult("CHUNK-800-999"))
        let term = makeTerminal(server: server, cols: 80)

        let more1 = try await term.loadOlderHistory(chunkRows: 200)
        XCTAssertTrue(more1)

        let firstRequest = try XCTUnwrap(server.receivedRequests.last { $0.method == "pane.selection.read" })
        let firstParams = try selectionReadParams(firstRequest.paramsJSON)
        XCTAssertEqual((firstParams["anchor"] as? [String: Any])?["row"] as? Int, 800)
        XCTAssertEqual((firstParams["cursor"] as? [String: Any])?["row"] as? Int, 999)
        XCTAssertEqual((firstParams["cursor"] as? [String: Any])?["col"] as? Int, 79)
        // `content_revision` is deliberately never sent: `pane.get`'s
        // `revision` is a different counter from herdr's content sequence
        // (confirmed against a real 0.9.0 server -- see PaneTerminal's
        // `readSelection` doc), so sending it would trip `stale_content` on
        // every real read.
        XCTAssertNil(firstParams["content_revision"])

        server.respond(to: "pane.selection.read", withResultJSON: selectionResult("CHUNK-600-799"))
        let more2 = try await term.loadOlderHistory(chunkRows: 200)
        XCTAssertTrue(more2)

        let secondRequest = try XCTUnwrap(server.receivedRequests.last { $0.method == "pane.selection.read" })
        let secondParams = try selectionReadParams(secondRequest.paramsJSON)
        XCTAssertEqual((secondParams["anchor"] as? [String: Any])?["row"] as? Int, 600)
        XCTAssertEqual((secondParams["cursor"] as? [String: Any])?["row"] as? Int, 799)

        // Oldest-first: the second (older) chunk sits before the first.
        XCTAssertEqual(term.historyText, "CHUNK-600-799CHUNK-800-999")

        // The total row count is fetched once via `pane.get`, not refetched
        // per chunk.
        let getCalls = server.receivedRequests.filter { $0.method == "pane.get" }
        XCTAssertEqual(getCalls.count, 1)
    }

    // MARK: - row 0 reached

    func testReachingAbsoluteRowZeroReturnsFalse() async throws {
        let server = FakeHerdrServer(); try server.start(); defer { server.stop() }
        server.respond(
            to: "pane.get",
            withResultJSON: #"{"type":"pane_info","pane":{"revision":1,"scroll":{"max_offset_from_bottom":0,"viewport_rows":150}}}"#
        )
        server.respond(to: "pane.selection.read", withResultJSON: selectionResult("CHUNK-0-149"))
        let term = makeTerminal(server: server)

        let more = try await term.loadOlderHistory(chunkRows: 200)
        XCTAssertFalse(more)

        let request = try XCTUnwrap(server.receivedRequests.last { $0.method == "pane.selection.read" })
        let params = try selectionReadParams(request.paramsJSON)
        XCTAssertEqual((params["anchor"] as? [String: Any])?["row"] as? Int, 0)
        XCTAssertEqual((params["cursor"] as? [String: Any])?["row"] as? Int, 149)
    }

    // MARK: - stale_content retries once

    func testStaleContentRetriesOnceThenSucceeds() async throws {
        let server = FakeHerdrServer(); try server.start(); defer { server.stop() }
        server.respond(to: "pane.get", withResultJSON: Self.paneGet1000Rows)
        server.failNext(method: "pane.selection.read", code: "stale_content", message: "pane content changed")
        server.respond(to: "pane.selection.read", withResultJSON: selectionResult("RECOVERED"))
        let term = makeTerminal(server: server)

        let more = try await term.loadOlderHistory(chunkRows: 200)
        XCTAssertTrue(more)
        XCTAssertEqual(term.historyText, "RECOVERED")
        XCTAssertFalse(term.historyChangedNotice)

        // One retry: the same request is repeated once, no extra `pane.get`.
        XCTAssertEqual(server.receivedRequests.filter { $0.method == "pane.get" }.count, 1)
        XCTAssertEqual(server.receivedRequests.filter { $0.method == "pane.selection.read" }.count, 2)
    }

    func testRetryFailureSurfacesHistoryChangedNoticeAndThrows() async throws {
        let server = FakeHerdrServer(); try server.start(); defer { server.stop() }
        server.respond(to: "pane.get", withResultJSON: Self.paneGet1000Rows)
        // Only the first `pane.selection.read` connection is armed; with no
        // persistent `respond` for that method, the retry's connection falls
        // through `FakeHerdrServer`'s own "no behavior configured" default --
        // a second, distinct failure without needing a queued one-shot.
        server.failNext(method: "pane.selection.read", code: "stale_content", message: "pane content changed")
        let term = makeTerminal(server: server)

        await XCTAssertThrowsErrorAsync(try await term.loadOlderHistory(chunkRows: 200)) {
            XCTAssertEqual($0 as? PaneHistoryError, .contentChanged)
        }
        XCTAssertTrue(term.historyChangedNotice)
        XCTAssertEqual(term.historyText, "", "a failed retry must not commit a chunk")
        XCTAssertEqual(server.receivedRequests.filter { $0.method == "pane.selection.read" }.count, 2)
    }

    // MARK: - capability gate

    func testUnknownMethodMarksCapabilityAbsentForSessionWithNoRetry() async throws {
        let server = FakeHerdrServer(); try server.start(); defer { server.stop() }
        server.respond(to: "pane.get", withResultJSON: Self.paneGet1000Rows)
        server.failNext(method: "pane.selection.read", code: "invalid_request", message: "unknown method")
        let gate = HistoryCapabilityGate()
        let term = makeTerminal(server: server, gate: gate)

        await XCTAssertThrowsErrorAsync(try await term.loadOlderHistory(chunkRows: 200)) {
            XCTAssertEqual($0 as? PaneHistoryError, .unsupported)
        }
        XCTAssertFalse(term.historyCapable)
        XCTAssertFalse(gate.isCapable)

        // Session-wide: a second `PaneTerminal` sharing the same gate is
        // already incapable and never issues a request.
        let requestCountBefore = server.receivedRequests.count
        let secondPane = makeTerminal(server: server, gate: gate)
        XCTAssertFalse(secondPane.historyCapable)
        await XCTAssertThrowsErrorAsync(try await secondPane.loadOlderHistory(chunkRows: 200)) {
            XCTAssertEqual($0 as? PaneHistoryError, .unsupported)
        }
        XCTAssertEqual(server.receivedRequests.count, requestCountBefore, "no retry: the gate short-circuits before any request")
    }

    // MARK: - concurrent calls coalesce

    /// `pane.selection.read` requests each open their own socket connection
    /// and can complete out of request order (confirmed by `HerdrClient`'s
    /// own connect-per-request contract). Before this test's fix, two
    /// overlapping `loadOlderHistory` calls both read the same
    /// `oldestFetchedRow`, both issued a REQUEST for the identical range,
    /// and `commitChunk`'s unconditional `insert(at: 0)` meant whichever
    /// response landed last decided the top of `historyText` -- silently
    /// duplicating or misordering scrollback depending on completion order.
    /// A concurrent caller now coalesces onto the one in-flight fetch
    /// instead of issuing a second request at all.
    func testConcurrentLoadOlderHistoryCallsCoalesceIntoOneRequest() async throws {
        let server = FakeHerdrServer(); try server.start(); defer { server.stop() }
        server.respond(to: "pane.get", withResultJSON: Self.paneGet1000Rows)
        server.respond(to: "pane.selection.read", withResultJSON: selectionResult("CHUNK-800-999"))
        let term = makeTerminal(server: server)

        let release = server.holdNext(method: "pane.selection.read")
        async let first = term.loadOlderHistory(chunkRows: 200)
        // Give the first call time to reach (and block on) the held request
        // before the second one starts, so both are genuinely in flight
        // together rather than trivially sequential.
        try await Task.sleep(nanoseconds: 50_000_000)
        async let second = term.loadOlderHistory(chunkRows: 200)
        try await Task.sleep(nanoseconds: 20_000_000)
        release()

        let (firstMore, secondMore) = try await (first, second)
        XCTAssertTrue(firstMore)
        XCTAssertTrue(secondMore)
        XCTAssertEqual(term.historyText, "CHUNK-800-999", "coalesced calls must not duplicate the chunk")
        XCTAssertEqual(
            server.receivedRequests.filter { $0.method == "pane.selection.read" }.count, 1,
            "the second call must coalesce onto the first in-flight fetch, never issuing its own request"
        )
    }
}
