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
/// `screenText` (a reader that can run concurrently, e.g. from a view).
public final class PaneTerminal: @unchecked Sendable {
    private let lock = NSLock()
    private let term: Terminal

    public init(cols: Int, rows: Int) {
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
}

private final class NullPaneTerminalDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}
