import Foundation
import SwiftTerm

/// Headless SwiftTerm bridge for one pane: feeds observe frames and backfill
/// ANSI into a `Terminal` with no view attached, so content correctness is
/// testable without AppKit. `PaneTerminalView` renders the same bytes through
/// SwiftTerm's own AppKit `TerminalView` for the live UI; this type exists so
/// the byte-level contract (full-frame reset, backfill-then-live ordering) has
/// a fast, headless test surface.
///
/// `Terminal` is not documented `Sendable` and is single-threaded internally;
/// the lock serializes `ingest`/`seedBackfill` (frame consumer) against
/// `screenText` (a reader that can run concurrently, e.g. from a view). The
/// same lock also guards the deep-history state added for Task 18b.
public final class PaneTerminal: @unchecked Sendable {
    private let lock = NSLock()
    private let term: Terminal
    private let cols: Int
    private let paneID: PaneID?
    private let client: (any HerdrCommandClient)?
    private let historyCapability: HistoryCapabilityGate

    // Deep-history state, protected by `lock`. `oldestFetchedRow` is the
    // absolute row just above the next chunk to fetch; nil until the first
    // `loadOlderHistory` call learns the pane's total row count from
    // `pane.get`, fetched once and never refreshed afterward (see
    // `readSelection`'s doc for why no revision is tracked here).
    private var oldestFetchedRow: Int?
    private var historyChunks: [String] = []
    private var storedHistoryChangedNotice = false

    public init(
        cols: Int,
        rows: Int,
        paneID: PaneID? = nil,
        client: (any HerdrCommandClient)? = nil,
        historyCapability: HistoryCapabilityGate = HistoryCapabilityGate()
    ) {
        self.cols = cols
        self.paneID = paneID
        self.client = client
        self.historyCapability = historyCapability
        term = Terminal(delegate: NullPaneTerminalDelegate(), options: TerminalOptions(cols: cols, rows: rows))
    }

    /// Seeds scrollback history before any live frame arrives. Never resets:
    /// backfill is meant to sit directly beneath the first live frame with no
    /// torn seam, per spike 4's backfill probe.
    public func seedBackfill(ansi: Data) {
        lock.lock()
        defer { lock.unlock() }
        term.feed(byteArray: [UInt8](ansi))
    }

    /// Applies `FrameFeeder`'s shared full-frame-reset rule against this
    /// headless terminal.
    public func ingest(_ frame: TerminalFrame) {
        lock.lock()
        defer { lock.unlock() }
        FrameFeeder.feed(frame, reset: { term.resetToInitialState() }, feed: { term.feed(byteArray: [UInt8]($0)) })
    }

    public func screenText() -> String {
        lock.lock()
        defer { lock.unlock() }
        return (0..<term.rows)
            .compactMap { term.getLine(row: $0)?.translateToString(trimRight: true) }
            .joined(separator: "\n")
    }

    // MARK: - Deep history (Task 18b)

    /// Plain scrollback fetched via `loadOlderHistory`, oldest-first. Rendered
    /// dimmed above the styled live buffer; empty until the first successful
    /// call.
    public var historyText: String {
        lock.lock()
        defer { lock.unlock() }
        return historyChunks.joined()
    }

    /// Set once a `stale_content` reply survives one retry. The view reads
    /// this to render a small notice rather than the throw itself carrying
    /// UI text.
    public var historyChangedNotice: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedHistoryChangedNotice
    }

    /// Whether this session's herdr server has confirmed support for
    /// `pane.selection.read`. Backed by the shared `HistoryCapabilityGate`
    /// passed at init, so one unsupported reply on any pane's
    /// `PaneTerminal` hides the affordance for every pane in the session.
    public var historyCapable: Bool { historyCapability.isCapable }

    /// Fetches the next older `chunkRows`-sized block of absolute rows via
    /// `pane.selection.read`, prepending it to `historyText`. Returns `false`
    /// once the fetch reaches absolute row 0 (nothing older remains), `true`
    /// otherwise.
    ///
    /// `content_revision` is never sent (see `readSelection`'s doc):
    /// `pane.get`'s `revision` field is a different counter from herdr's own
    /// internal content sequence, confirmed against a real 0.9.0 server, so a
    /// `stale_content` reply from this client can currently only come from a
    /// canned test failure or a future/unrelated server behavior -- the retry
    /// exists for that case, not because the normal path expects to hit it.
    ///
    /// The first reply whose error code means the method is unknown or
    /// unsupported marks the capability gate absent for the whole session and
    /// throws `PaneHistoryError.unsupported` -- not retried. A `stale_content`
    /// reply is retried once, identically; a second failure sets
    /// `historyChangedNotice` and throws `PaneHistoryError.contentChanged`.
    public func loadOlderHistory(chunkRows: Int) async throws -> Bool {
        guard chunkRows > 0 else { return false }
        guard let client, let paneID else { throw PaneHistoryError.unsupported }
        guard historyCapability.isCapable else { throw PaneHistoryError.unsupported }

        try await ensureInitialized(client: client, paneID: paneID)

        let (startRow, endRow) = lock.withLockHeld { () -> (Int, Int) in
            let pointer = oldestFetchedRow ?? 0
            return (max(0, pointer - chunkRows), pointer - 1)
        }
        guard endRow >= startRow else { return false }

        do {
            let text = try await readSelection(client: client, paneID: paneID, startRow: startRow, endRow: endRow)
            commitChunk(text, startRow: startRow)
            return startRow > 0
        } catch let HerdrClientError.server(code, _) where Self.isCapabilityLossCode(code) {
            historyCapability.markUnsupported()
            throw PaneHistoryError.unsupported
        } catch HerdrClientError.server("stale_content", _) {
            return try await retryAfterStaleContent(client: client, paneID: paneID, startRow: startRow, endRow: endRow)
        }
    }

    private func retryAfterStaleContent(
        client: any HerdrCommandClient, paneID: PaneID, startRow: Int, endRow: Int
    ) async throws -> Bool {
        do {
            let text = try await readSelection(client: client, paneID: paneID, startRow: startRow, endRow: endRow)
            commitChunk(text, startRow: startRow)
            return startRow > 0
        } catch {
            lock.withLockHeld { storedHistoryChangedNotice = true }
            throw PaneHistoryError.contentChanged
        }
    }

    private func commitChunk(_ text: String, startRow: Int) {
        lock.withLockHeld {
            historyChunks.insert(text, at: 0)
            oldestFetchedRow = startRow
        }
    }

    private func ensureInitialized(client: any HerdrCommandClient, paneID: PaneID) async throws {
        guard lock.withLockHeld({ oldestFetchedRow == nil }) else { return }
        let rowCount = try await fetchTotalRowCount(client: client, paneID: paneID)
        lock.withLockHeld {
            guard oldestFetchedRow == nil else { return }
            oldestFetchedRow = rowCount
        }
    }

    /// `pane.get`'s wire shape nests fields under a `"pane"` key alongside a
    /// `"type"` tag (verified against herdr's response schema); only
    /// `scroll` is read here, so every other `PaneInfo` field is left
    /// undeclared and ignored by the decoder.
    private func fetchTotalRowCount(client: any HerdrCommandClient, paneID: PaneID) async throws -> Int {
        struct ScrollPayload: Decodable {
            let maxOffsetFromBottom: Int
            let viewportRows: Int
            enum CodingKeys: String, CodingKey {
                case maxOffsetFromBottom = "max_offset_from_bottom"
                case viewportRows = "viewport_rows"
            }
        }
        struct PanePayload: Decodable { let scroll: ScrollPayload? }
        struct Result: Decodable { let pane: PanePayload }
        struct Envelope: Decodable { let result: Result }

        let data = try await client.requestRaw("pane.get", ["pane_id": .string(paneID.rawValue)])
        let scroll = try JSONDecoder().decode(Envelope.self, from: data).result.pane.scroll
        return (scroll?.maxOffsetFromBottom ?? 0) + (scroll?.viewportRows ?? 0)
    }

    /// `anchor`/`cursor` address absolute rows, never the live viewport, per
    /// the brief's recipe. `content_revision` is deliberately omitted:
    /// `PaneSelectionReadParams.content_revision` is optional specifically so
    /// a caller with no reliable revision can skip herdr's staleness check
    /// (see `runtime.content_seq()` in herdr's `pane_selection_text`) rather
    /// than send a value proven wrong -- `pane.get`'s `revision` field is a
    /// title-change counter, not the content sequence, confirmed by reading
    /// `terminal.revision` against a real 0.9.0 server after 2500+ lines of
    /// output left it at `0`, which then made every `content_revision:0`
    /// request fail `stale_content` immediately and permanently.
    private func readSelection(
        client: any HerdrCommandClient, paneID: PaneID, startRow: Int, endRow: Int
    ) async throws -> String {
        let params: [String: JSONValue] = [
            "pane_id": .string(paneID.rawValue),
            "anchor": .object(["row": .int(startRow), "col": .int(0)]),
            "cursor": .object(["row": .int(endRow), "col": .int(max(0, cols - 1))]),
        ]
        let data = try await client.requestRaw("pane.selection.read", params)
        struct Result: Decodable { let text: String }
        struct Envelope: Decodable { let result: Result }
        return try JSONDecoder().decode(Envelope.self, from: data).result.text
    }

    /// herdr's docs say an unsupported method is "handled as a normal
    /// error"; `invalid_request` is the code its wire layer actually returns
    /// for a request whose `method` tag does not decode (verified against
    /// `server.rs`'s `handle_connection_with_stop`). The others are kept as a
    /// defensive allowance for a future/renamed code, per the brief.
    private static func isCapabilityLossCode(_ code: String) -> Bool {
        switch code {
        case "invalid_request", "unknown_method", "method_not_found", "unsupported_method":
            true
        default:
            false
        }
    }
}

/// Session-wide record of whether the connected herdr server supports
/// `pane.selection.read`. Shared by reference across every pane's
/// `PaneTerminal` in one connected session: the first unknown-method reply
/// marks it absent for everyone, since the capability belongs to the server,
/// not to any one pane.
public final class HistoryCapabilityGate: @unchecked Sendable {
    private let lock = NSLock()
    private var capable = true

    public init() {}

    public var isCapable: Bool { lock.withLockHeld { capable } }

    func markUnsupported() {
        lock.withLockHeld { capable = false }
    }
}

public enum PaneHistoryError: Error, Equatable, Sendable {
    /// The server's first reply to `loadOlderHistory` looked like an
    /// unknown/unsupported method; the capability gate is now marked absent
    /// and this pane's call was not retried.
    case unsupported
    /// A `stale_content` reply survived one identical retry;
    /// `historyChangedNotice` is now `true`.
    case contentChanged
}

private extension NSLock {
    func withLockHeld<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

private final class NullPaneTerminalDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}
