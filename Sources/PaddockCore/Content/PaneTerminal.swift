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
/// same lock also guards the deep-history state below.
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
    // Coalescing guard for `loadOlderHistory`: see its own doc comment.
    private var isLoadingHistory = false
    private var historyLoadWaiters: [CheckedContinuation<Bool, Error>] = []
    // Line count of whatever `seedBackfill` fed in, so the first
    // `loadOlderHistory` call anchors `oldestFetchedRow` at the row
    // directly above what the live view already shows -- never at the
    // pane's total row count, which would leave an unshown, uncommunicated
    // gap between the loaded history and the live buffer's own top.
    private var backfillLineCount = 0

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

    /// Test-only seam: a caller-supplied delegate observes the
    /// `showCursor`/`hideCursor` calls `seedBackfill`'s `BackfillFeed` prefix
    /// and a subsequent full-frame ingest drive, which the public initializer
    /// has no way to expose since `NullPaneTerminalDelegate` is silent by
    /// design.
    init(cols: Int, rows: Int, delegate: TerminalDelegate) {
        self.cols = cols
        self.paneID = nil
        self.client = nil
        self.historyCapability = HistoryCapabilityGate()
        term = Terminal(delegate: delegate, options: TerminalOptions(cols: cols, rows: rows))
    }

    /// Seeds scrollback history before any live frame arrives. Never resets:
    /// backfill is meant to sit directly beneath the first live frame with no
    /// torn seam, per spike 4's backfill probe.
    ///
    /// `lineCount`, when given, MUST be the number of rows actually rendered
    /// in `ansi` -- NOT the `lines` value a caller requested from
    /// `pane.read`. herdr's own recent-read range (`ghostty_recent_read_range`)
    /// anchors its end at the last non-blank row or the cursor row,
    /// whichever is greater, which can fall short of the pane's true last
    /// row whenever trailing rows are blank -- so a `lines:1000` request can
    /// return FEWER than 1000 actual rows. Trusting the requested count over
    /// the real one reproduced a live, reviewer-caught bug: the deep-history
    /// anchor landed short of the live buffer's true top by exactly the
    /// shortfall, leaving an unshown gap between the two. Default (no
    /// `lineCount` given) measures the real row count directly from `ansi`.
    public func seedBackfill(ansi: Data, lineCount: Int? = nil) {
        lock.lock()
        defer { lock.unlock() }
        term.feed(byteArray: [UInt8](BackfillFeed.bytes(prefixing: ansi)))
        backfillLineCount = lineCount ?? Self.countLines(in: ansi)
    }

    /// Counts rendered rows as newline-delimited segments: `N` newlines make
    /// `N + 1` rows when the text has no trailing newline (the common case --
    /// the cursor sits mid-row at a live prompt), `N` rows when it does.
    private static func countLines(in ansi: Data) -> Int {
        guard !ansi.isEmpty else { return 0 }
        let newlineCount = ansi.reduce(into: 0) { count, byte in if byte == 0x0A { count += 1 } }
        return ansi.last == 0x0A ? newlineCount : newlineCount + 1
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

    /// Count of visible rows with any non-whitespace content -- the
    /// pristine-launcher heuristic: a bare shell prompt is at most 2 such
    /// rows (the shell's own startup line, if any, and the prompt line
    /// itself).
    public func nonEmptyRowCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return (0..<term.rows).reduce(into: 0) { count, row in
            guard let line = term.getLine(row: row)?.translateToString(trimRight: true) else { return }
            if !line.trimmingCharacters(in: .whitespaces).isEmpty { count += 1 }
        }
    }

    // MARK: - Deep history

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

    /// Registers `listener` to fire the moment the shared gate flips to
    /// unsupported (never fired if it is already unsupported at
    /// registration time -- callers check `historyCapable` themselves for
    /// that case). Lets a view hide the history region reactively on a
    /// pane whose OWN `loadOlderHistory` never ran, since the capability is
    /// session-wide, not per-pane. Returns a token for `removeHistoryCapabilityListener`.
    @discardableResult
    public func onHistoryCapabilityLost(_ listener: @escaping @Sendable () -> Void) -> UUID {
        historyCapability.addListener(listener)
    }

    public func removeHistoryCapabilityListener(_ token: UUID) {
        historyCapability.removeListener(token)
    }

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
    /// A concurrent second call while one is already in flight coalesces
    /// onto the SAME fetch instead of issuing its own `pane.selection.read`:
    /// each request opens its own socket connection (`HerdrClient`'s
    /// connect-per-request contract) and responses can land out of request
    /// order, so two overlapping calls would otherwise both read the same
    /// `oldestFetchedRow`, both request the identical range, and
    /// `commitChunk`'s unconditional `insert(at: 0)` would let whichever
    /// response arrived last silently duplicate or misorder `historyText`.
    public func loadOlderHistory(chunkRows: Int) async throws -> Bool {
        guard chunkRows > 0 else { return false }
        guard let client, let paneID else { throw PaneHistoryError.unsupported }
        guard historyCapability.isCapable else { throw PaneHistoryError.unsupported }

        let shouldRunFetch = lock.withLockHeld { () -> Bool in
            guard !isLoadingHistory else { return false }
            isLoadingHistory = true
            return true
        }
        guard shouldRunFetch else {
            return try await withCheckedThrowingContinuation { continuation in
                lock.withLockHeld { historyLoadWaiters.append(continuation) }
            }
        }

        do {
            let result = try await performLoadOlderHistory(client: client, paneID: paneID, chunkRows: chunkRows)
            resumeWaiters(.success(result))
            return result
        } catch {
            resumeWaiters(.failure(error))
            throw error
        }
    }

    private func performLoadOlderHistory(
        client: any HerdrCommandClient, paneID: PaneID, chunkRows: Int
    ) async throws -> Bool {
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

    private func resumeWaiters(_ result: Result<Bool, Error>) {
        let waiters: [CheckedContinuation<Bool, Error>] = lock.withLockHeld {
            isLoadingHistory = false
            defer { historyLoadWaiters.removeAll() }
            return historyLoadWaiters
        }
        for waiter in waiters {
            switch result {
            case .success(let value): waiter.resume(returning: value)
            case .failure(let error): waiter.resume(throwing: error)
            }
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

    /// Anchors `oldestFetchedRow` at the absolute row directly above what
    /// this terminal ACTUALLY RETAINS locally -- probed from the buffer
    /// itself, never from fed-line bookkeeping. Backfill can feed more
    /// lines than the scrollback limit keeps (the buffer silently trims its
    /// oldest rows), so `backfillLineCount`-based arithmetic drifts by
    /// exactly the trimmed amount and leaves an unshown gap between the
    /// first history chunk and the oldest visible row. The probe measures
    /// retention truth, which also collapses the fresh-pane case: a pane
    /// whose retained rows already cover herdr's total has no older history
    /// (anchor 0, first load answers false).
    private func ensureInitialized(client: any HerdrCommandClient, paneID: PaneID) async throws {
        guard lock.withLockHeld({ oldestFetchedRow == nil }) else { return }
        let (totalRows, _) = try await fetchScrollBounds(client: client, paneID: paneID)
        // The rendered terminal mutates on the main actor (its feed task);
        // probing it must hop there, or the probe races a mid-feed buffer.
        let held: Int
        if let localRetentionProvider {
            held = await MainActor.run { localRetentionProvider() }
        } else {
            held = locallyHeldRowCount()
        }
        lock.withLockHeld {
            guard oldestFetchedRow == nil else { return }
            oldestFetchedRow = max(0, totalRows - held)
        }
    }

    /// When set, overrides the headless probe as the source of locally-held
    /// truth. The RENDERED terminal is a second SwiftTerm instance whose
    /// retention can diverge from the headless mirror (full-frame resets
    /// land at different effective points in each stream), and adjacency is
    /// owed to what the USER SEES -- so the view layer hands its own
    /// terminal's probed count in here.
    public var localRetentionProvider: (@MainActor () -> Int)?

    /// The rendered terminal's full retained text (scrollback + screen,
    /// trimmed), same divergence rationale as `localRetentionProvider`:
    /// the history browser shows the live buffer AS THE USER'S VIEW HOLDS
    /// IT, so fetched history and buffer text meet with no gap by
    /// construction.
    public var localRetainedTextProvider: (@MainActor () -> String)?

    /// All rows a terminal's buffer currently holds, joined by newlines
    /// (probe window per `heldRowCount(of:)`).
    public static func retainedText(of term: Terminal) -> String {
        let stride = max(1, term.rows)
        var inside = -1
        var probe = 0
        while probe <= 50_000_000 {
            if term.getScrollInvariantLine(row: probe) != nil { inside = probe; break }
            probe += stride
        }
        if inside < 0 { return "" }
        var row = inside
        if term.getScrollInvariantLine(row: 0) != nil {
            row = 0
        } else {
            var lowInvalid = max(0, inside - stride)
            var lowValid = inside
            while lowValid - lowInvalid > 1 {
                let mid = (lowInvalid + lowValid) / 2
                if term.getScrollInvariantLine(row: mid) == nil { lowInvalid = mid } else { lowValid = mid }
            }
            row = lowValid
        }
        var lines: [String] = []
        while let line = term.getScrollInvariantLine(row: row) {
            lines.append(line.translateToString(trimRight: true))
            row += 1
        }
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// The number of rows (scrollback plus screen) a terminal's buffer
    /// holds right now, measured through the public scroll-invariant row
    /// accessor: valid rows form one contiguous window whose lower edge
    /// rises as the circular buffer trims, so an exponential probe finds a
    /// valid row and two binary searches find the window's edges. Exact
    /// where any fed-line counter drifts by whatever trimming discarded.
    func locallyHeldRowCount() -> Int {
        lock.withLockHeld { Self.heldRowCount(of: term) }
    }

    /// Same probe, callable against ANY SwiftTerm `Terminal` (the view
    /// layer uses it on its rendered instance for `localRetentionProvider`).
    ///
    /// Valid rows form one contiguous window `[linesTop, linesTop + count)`
    /// whose edges are not public. The window always spans at least the
    /// screen's `rows`, so striding by `rows` from zero cannot step over it
    /// (a pure doubling probe can, and did: 1024 -> 2048 clears a window
    /// ending at 2040 entirely); once any valid row is found, each edge is
    /// binary-searched on its own monotonic side.
    public static func heldRowCount(of term: Terminal) -> Int {
        let stride = max(1, term.rows)
        var inside = -1
        var probe = 0
        while probe <= 50_000_000 {
            if term.getScrollInvariantLine(row: probe) != nil { inside = probe; break }
            probe += stride
        }
        if inside < 0 { return 0 }

        var lowValid = inside
        if term.getScrollInvariantLine(row: 0) != nil {
            lowValid = 0
        } else {
            var lowInvalid = max(0, inside - stride)
            while lowValid - lowInvalid > 1 {
                let mid = (lowInvalid + lowValid) / 2
                if term.getScrollInvariantLine(row: mid) == nil { lowInvalid = mid } else { lowValid = mid }
            }
        }

        var hiValid = inside
        var hiInvalid = inside + 1
        while term.getScrollInvariantLine(row: hiInvalid) != nil { hiInvalid *= 2 }
        while hiInvalid - hiValid > 1 {
            let mid = (hiValid + hiInvalid) / 2
            if term.getScrollInvariantLine(row: mid) != nil { hiValid = mid } else { hiInvalid = mid }
        }
        return hiValid - lowValid + 1
    }



    /// `pane.get`'s wire shape nests fields under a `"pane"` key alongside a
    /// `"type"` tag (verified against herdr's response schema); only
    /// `scroll` is read here, so every other `PaneInfo` field is left
    /// undeclared and ignored by the decoder.
    private func fetchScrollBounds(
        client: any HerdrCommandClient, paneID: PaneID
    ) async throws -> (totalRows: Int, maxOffsetFromBottom: Int) {
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
        let maxOffsetFromBottom = scroll?.maxOffsetFromBottom ?? 0
        return (maxOffsetFromBottom + (scroll?.viewportRows ?? 0), maxOffsetFromBottom)
    }

    /// `anchor`/`cursor` address absolute rows, never the live viewport.
    /// `content_revision` is deliberately omitted:
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
    /// defensive allowance in case herdr renames or adds a code for this
    /// condition later.
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
    private var listeners: [UUID: @Sendable () -> Void] = [:]

    public init() {}

    public var isCapable: Bool { lock.withLockHeld { capable } }

    func markUnsupported() {
        let toNotify: [@Sendable () -> Void] = lock.withLockHeld {
            guard capable else { return [] }
            capable = false
            let fired = Array(listeners.values)
            listeners.removeAll()
            return fired
        }
        for notify in toNotify { notify() }
    }

    @discardableResult
    func addListener(_ listener: @escaping @Sendable () -> Void) -> UUID {
        let token = UUID()
        lock.withLockHeld {
            guard capable else { return }
            listeners[token] = listener
        }
        return token
    }

    func removeListener(_ token: UUID) {
        lock.withLockHeld { _ = listeners.removeValue(forKey: token) }
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
