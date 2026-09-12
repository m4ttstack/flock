import Foundation

/// Deep-history helper for one pane: fetches older scrollback chunks via
/// `pane.selection.read` and anchors them against whatever the pane's LIVE
/// renderer actually retains locally right now, read through
/// `localRetentionProvider`/`localRetainedTextProvider` (ghostty's own
/// retained screen -- `GhosttySession.retainedRowCount`/`retainedText` --
/// since 18j; there is exactly one buffer per pane to stay adjacent to,
/// never a second, headless mirror kept only for this class's own use).
///
/// `Terminal` played that mirroring role before 18m's mode-switching bridge:
/// SwiftTerm rendered every unfocused pane and this type fed it the same
/// backfill/frame bytes headlessly so deep history had something local to
/// probe without AppKit. Ghostty now renders every pane directly, so the
/// probe reads the real thing instead.
public final class PaneTerminal: @unchecked Sendable {
    private let lock = NSLock()
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

    public init(
        cols: Int,
        paneID: PaneID? = nil,
        client: (any HerdrCommandClient)? = nil,
        historyCapability: HistoryCapabilityGate = HistoryCapabilityGate()
    ) {
        self.cols = cols
        self.paneID = paneID
        self.client = client
        self.historyCapability = historyCapability
    }

    // MARK: - Deep history

    /// Plain scrollback fetched via `loadOlderHistory`, oldest-first. Rendered
    /// dimmed above the styled live buffer; empty until the first successful
    /// call.
    public var historyText: String {
        lock.withLockHeld { historyChunks.joined() }
    }

    /// Set once a `stale_content` reply survives one retry. The view reads
    /// this to render a small notice rather than the throw itself carrying
    /// UI text.
    public var historyChangedNotice: Bool {
        lock.withLockHeld { storedHistoryChangedNotice }
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
    /// the pane's live renderer ACTUALLY RETAINS locally, probed via
    /// `localRetentionProvider` -- never from fed-line bookkeeping, since a
    /// renderer's scrollback limit can trim below however many lines were
    /// ever fed to it, and the anchor is owed to what the buffer holds, not
    /// what it was told. `held` is `0` when no provider is set (nothing
    /// locally retained), which fetches from the pane's absolute total --
    /// production always sets a provider (`GhosttySurfaceRepresentable`
    /// wires it at attach), so this only matters for a caller-supplied
    /// `PaneTerminal` with no rendered view behind it yet.
    private func ensureInitialized(client: any HerdrCommandClient, paneID: PaneID) async throws {
        guard lock.withLockHeld({ oldestFetchedRow == nil }) else { return }
        let (totalRows, _) = try await fetchScrollBounds(client: client, paneID: paneID)
        let held = await MainActor.run { localRetentionProvider?() ?? 0 }
        lock.withLockHeld {
            guard oldestFetchedRow == nil else { return }
            oldestFetchedRow = max(0, totalRows - held)
        }
    }

    /// The pane's live renderer's currently-held row count (scrollback plus
    /// screen), read on the main actor since the renderer mutates there.
    /// Wired by the view layer at attach time
    /// (`GhosttySurfaceRepresentable.makeNSView`) from
    /// `GhosttySession.retainedRowCount`.
    public var localRetentionProvider: (@MainActor () -> Int)?

    /// The pane's live renderer's full retained text (scrollback + screen,
    /// trimmed) -- the history browser shows the live buffer AS THE USER'S
    /// VIEW HOLDS IT, so fetched history and buffer text meet with no gap
    /// by construction. Wired alongside `localRetentionProvider`.
    public var localRetainedTextProvider: (@MainActor () -> String)?

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
