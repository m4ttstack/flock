import XCTest
@testable import PaddockCore

/// Answers `pane.get` with a fixed total row count and `pane.selection.read`
/// by echoing back numbered `"line N"` rows for whatever `anchor`/`cursor`
/// range was actually requested, rather than a fixed canned string --
/// content-level ground truth a test can check for numeric adjacency,
/// immune to a wrong request happening to still look plausible.
private actor NumberedContentClient: HerdrCommandClient {
    private let totalRows: Int

    init(totalRows: Int) {
        self.totalRows = totalRows
    }

    func requestRaw(_ method: String, _ params: [String: JSONValue]) async throws -> Data {
        switch method {
        case "pane.get":
            return Data(
                #"{"result":{"pane":{"revision":0,"scroll":{"max_offset_from_bottom":\#(totalRows - 40),"viewport_rows":40}}}}"#
                    .utf8
            )
        case "pane.selection.read":
            guard case .object(let anchor)? = params["anchor"], case .int(let startRow)? = anchor["row"],
                  case .object(let cursor)? = params["cursor"], case .int(let endRow)? = cursor["row"],
                  endRow >= startRow
            else { return Data(#"{"result":{"text":""}}"#.utf8) }
            let text = (startRow...endRow).map { "line \($0)" }.joined(separator: "\\n")
            return Data(#"{"result":{"text":"\#(text)"}}"#.utf8)
        default:
            return Data("{}".utf8)
        }
    }
}

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

    // MARK: - retention probe ground truth

    /// Pins `locallyHeldRowCount` against values computed BY HAND from
    /// SwiftTerm's buffer model: a fresh terminal holds exactly its screen
    /// rows; the first `rows - 1` newlines only walk the cursor down that
    /// blank screen, and every newline past the bottom pushes one row into
    /// scrollback (held = rows + max(0, fed - (rows - 1))) until the
    /// scrollback limit caps it -- independent ground truth, so the anchor
    /// tests elsewhere may derive expectations from the probe without the
    /// whole chain becoming self-referential.
    func testLocallyHeldRowCountMatchesHandComputedRetention() {
        let server = FakeHerdrServer(); try? server.start(); defer { server.stop() }
        let term = makeTerminal(server: server)
        XCTAssertEqual(term.locallyHeldRowCount(), 24, "a fresh terminal holds exactly its screen rows")

        term.seedBackfill(ansi: Data(String(repeating: "x\n", count: 40).utf8), lineCount: 40)
        XCTAssertEqual(term.locallyHeldRowCount(), 41, "24 screen rows + (40 - 23) rows pushed into scrollback")

        term.seedBackfill(ansi: Data(String(repeating: "y\n", count: 2000).utf8), lineCount: 2000)
        XCTAssertEqual(
            term.locallyHeldRowCount(), 524,
            "beyond the limit the buffer caps at scrollback (500) plus screen rows (24)")
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
        // Backfill FEEDS 800 lines, but the terminal's scrollback limit
        // retains fewer -- the anchor must sit above what the buffer
        // actually HOLDS (the on-screen truth), not above the fed count.
        term.seedBackfill(ansi: Data(String(repeating: "x\n", count: 800).utf8), lineCount: 800)
        let held = term.locallyHeldRowCount()
        XCTAssertLessThan(held, 800, "premise: the buffer trims below the fed count")
        let oldestHeldAbsoluteRow = 1000 - held

        _ = try await term.loadOlderHistory(chunkRows: 200)

        let request = try XCTUnwrap(server.receivedRequests.last { $0.method == "pane.selection.read" })
        let params = try selectionReadParams(request.paramsJSON)
        XCTAssertEqual(
            (params["cursor"] as? [String: Any])?["row"] as? Int, oldestHeldAbsoluteRow - 1,
            "must end exactly where the locally retained buffer begins, not overlap it")
        XCTAssertEqual((params["anchor"] as? [String: Any])?["row"] as? Int, max(0, oldestHeldAbsoluteRow - 200))
    }

    /// Content-level, not request-params-level: seeds backfill with REAL
    /// numbered rows and answers `pane.selection.read` by echoing back
    /// numbered rows for whatever range was actually requested (not a fixed
    /// canned string) -- so a wrong anchor shows up as non-adjacent numbers,
    /// not as a param assertion that can pass for the wrong reason.
    ///
    /// Modeled on a real, reviewer-caught defect: herdr's recent-read range
    /// (`ghostty_recent_read_range`) can return FEWER rows than the `lines`
    /// value a caller requested (its `end` anchor is the last non-blank row
    /// or the cursor row, whichever is greater -- short of the pane's true
    /// last row whenever trailing rows are blank). Trusting the requested
    /// count over the real one left the deep-history anchor short of the
    /// live buffer's true top by exactly the shortfall -- a live,
    /// screenshot-confirmed gap between the dimmed history band and the
    /// live buffer, with nothing shown for the skipped rows.
    func testHistoryContentStaysNumericallyAdjacentToBackfillEvenWhenFewerRowsReturnedThanRequested() async throws {
        // A `lines: 1000` request (`requestedLines`) but the "server" only
        // ever rendered the last 960 real rows -- production must anchor on
        // the 960 actually seeded, never the 1000 requested.
        let totalRows = 1200
        let actualBackfillRows = 960
        let backfillFirstRow = totalRows - actualBackfillRows // 240

        let client = NumberedContentClient(totalRows: totalRows)
        let term = PaneTerminal(cols: 80, rows: 24, paneID: PaneID(rawValue: "w1:p1"), client: client)
        let backfillText = (backfillFirstRow..<totalRows).map { "line \($0)" }.joined(separator: "\n")
        term.seedBackfill(ansi: Data(backfillText.utf8))
        // The buffer may retain fewer rows than were seeded; adjacency is
        // owed to the oldest row it actually HOLDS (what the user can see),
        // which the anchor derives by probing retention.
        let oldestHeldAbsoluteRow = totalRows - term.locallyHeldRowCount()

        _ = try await term.loadOlderHistory(chunkRows: 200)

        let lastHistoryLine = term.historyText.split(separator: "\n").last.map(String.init) ?? ""
        let lastHistoryRow = try XCTUnwrap(Int(lastHistoryLine.dropFirst("line ".count)))
        XCTAssertEqual(
            lastHistoryRow + 1, oldestHeldAbsoluteRow,
            "the last loaded history row must be numerically adjacent to the oldest locally retained row -- no gap, no overlap"
        )
    }

    // MARK: - sequential chunks + oldest-first accumulation

    func testSequentialChunksRequestDecreasingAbsoluteRowRangesAndAccumulateOldestFirst() async throws {
        let server = FakeHerdrServer(); try server.start(); defer { server.stop() }
        server.respond(to: "pane.get", withResultJSON: Self.paneGet1000Rows)
        server.respond(to: "pane.selection.read", withResultJSON: selectionResult("CHUNK-600-799"))
        let term = makeTerminal(server: server, cols: 80)

        // No backfill seeded here (pure chunk mechanics): the terminal
        // holds only its blank screen rows, so the anchor sits directly
        // above those -- derived, like production, from probed retention.
        let firstTop = 1000 - term.locallyHeldRowCount()
        let more1 = try await term.loadOlderHistory(chunkRows: 200)
        XCTAssertTrue(more1)

        let firstRequest = try XCTUnwrap(server.receivedRequests.last { $0.method == "pane.selection.read" })
        let firstParams = try selectionReadParams(firstRequest.paramsJSON)
        XCTAssertEqual((firstParams["anchor"] as? [String: Any])?["row"] as? Int, firstTop - 200)
        XCTAssertEqual((firstParams["cursor"] as? [String: Any])?["row"] as? Int, firstTop - 1)
        XCTAssertEqual((firstParams["cursor"] as? [String: Any])?["col"] as? Int, 79)
        // `content_revision` is deliberately never sent: `pane.get`'s
        // `revision` is a different counter from herdr's content sequence
        // (confirmed against a real 0.9.0 server -- see PaneTerminal's
        // `readSelection` doc), so sending it would trip `stale_content` on
        // every real read.
        XCTAssertNil(firstParams["content_revision"])

        server.respond(to: "pane.selection.read", withResultJSON: selectionResult("CHUNK-400-599"))
        let more2 = try await term.loadOlderHistory(chunkRows: 200)
        XCTAssertTrue(more2)

        let secondRequest = try XCTUnwrap(server.receivedRequests.last { $0.method == "pane.selection.read" })
        let secondParams = try selectionReadParams(secondRequest.paramsJSON)
        XCTAssertEqual((secondParams["anchor"] as? [String: Any])?["row"] as? Int, firstTop - 400)
        XCTAssertEqual((secondParams["cursor"] as? [String: Any])?["row"] as? Int, firstTop - 201)

        // Oldest-first: the second (older) chunk sits before the first.
        XCTAssertEqual(term.historyText, "CHUNK-400-599CHUNK-600-799")

        // The total row count is fetched once via `pane.get`, not refetched
        // per chunk.
        let getCalls = server.receivedRequests.filter { $0.method == "pane.get" }
        XCTAssertEqual(getCalls.count, 1)
    }

    // MARK: - row 0 reached

    func testReachingAbsoluteRowZeroReturnsFalse() async throws {
        // max_offset_from_bottom: 100 -- genuine scrollback exists above the
        // viewport, so the anchor is NOT short-circuited to 0 (see
        // testEmptyScrollbackNeverIssuesARequestEvenWithoutBackfillSeeded
        // below for that case).
        let server = FakeHerdrServer(); try server.start(); defer { server.stop() }
        server.respond(
            to: "pane.get",
            withResultJSON: #"{"type":"pane_info","pane":{"revision":1,"scroll":{"max_offset_from_bottom":100,"viewport_rows":150}}}"#
        )
        server.respond(to: "pane.selection.read", withResultJSON: selectionResult("CHUNK-0-99"))
        let term = makeTerminal(server: server)
        // total rows = 100 + 150; a chunk bigger than the whole span must
        // clamp its start to absolute row 0 and answer false (no older).
        let top = 250 - term.locallyHeldRowCount()

        let more = try await term.loadOlderHistory(chunkRows: 300)
        XCTAssertFalse(more)

        let request = try XCTUnwrap(server.receivedRequests.last { $0.method == "pane.selection.read" })
        let params = try selectionReadParams(request.paramsJSON)
        XCTAssertEqual((params["anchor"] as? [String: Any])?["row"] as? Int, 0)
        XCTAssertEqual((params["cursor"] as? [String: Any])?["row"] as? Int, top - 1)
    }

    /// Reported live: a nearly-empty pane (a fresh shell, no real scrollback
    /// yet) showed its own current prompt DUPLICATED in the dimmed history
    /// region. Root cause: anchoring purely on `totalRows - backfillLineCount`
    /// assumes backfill's snapshot sits at the tail of the pane's total row
    /// count -- true only when the cursor is at the true bottom (a
    /// long-scrollback pane). herdr's own recent-read range anchors on the
    /// cursor/last-content row instead, which for a fresh, mostly-blank
    /// pane can sit near the TOP of the viewport, nowhere near
    /// `totalRows - 1`. `max_offset_from_bottom == 0` means there is no
    /// real scrollback above the (always-live) current viewport at all, so
    /// `loadOlderHistory` must report "nothing more" without ever issuing a
    /// request, regardless of what backfill's own line count happens to be.
    func testEmptyScrollbackNeverIssuesARequestEvenWithoutBackfillSeeded() async throws {
        let server = FakeHerdrServer(); try server.start(); defer { server.stop() }
        server.respond(
            to: "pane.get",
            withResultJSON: #"{"type":"pane_info","pane":{"revision":1,"scroll":{"max_offset_from_bottom":0,"viewport_rows":24}}}"#
        )
        // viewport_rows matches the local terminal's rows, as production
        // dims always do: the blank screen alone then covers the pane's
        // whole (scrollback-free) total, so nothing older can exist.
        let term = makeTerminal(server: server)

        let more = try await term.loadOlderHistory(chunkRows: 200)

        XCTAssertFalse(more)
        XCTAssertEqual(term.historyText, "")
        XCTAssertEqual(
            server.receivedRequests.filter { $0.method == "pane.selection.read" }.count, 0,
            "no genuine scrollback exists above the live viewport; must never request rows the live view already covers"
        )
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
