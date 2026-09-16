// Portions derived from Herdglass (BSL-1.1), Sources/HerdrClient/PaneControlChannel.swift.
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Out-of-band bridge -> GUI channel, one FIFO per attached pane -- the mirror
/// of `PaneControlChannel`, in the opposite direction. The GUI creates the
/// FIFO and reads it; the bridge opens the path from its `--status-pipe` argv
/// and writes to it.
///
/// It carries only what the surface's own PTY stream (`terminal.frame`) drops:
/// today, `paddock.mouse_capture` lines, so the app learns when the pane's
/// program turns mouse reporting on or off. Paddock's libghostty never enters
/// reporting mode itself (its screen is a repaint of herdr's, never the raw
/// DECSET), so this out-of-band signal is the only way the view knows whether
/// to forward a click to the app or let libghostty select.
public final class PaneStatusChannel {
    /// Environment variable the bridge reads the FIFO path from, mirroring
    /// `PaneControlChannel.environmentKey`.
    public static let environmentKey = "HERDR_TERM_STATUS_PIPE"

    public let path: String
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private let buffer = StatusLineBuffer()

    /// Returns nil when the FIFO cannot be made; the pane then never learns
    /// its mouse-capture state and every click takes the selection path (the
    /// pre-passthrough behavior). `GhosttyControlSurfaceFactory` logs this,
    /// like the control-channel failure, but it degrades gracefully rather
    /// than losing input entirely.
    public init?(directory: URL = FileManager.default.temporaryDirectory) {
        let name = "paddock-\(UUID().uuidString.prefix(8)).status"
        let url = directory.appendingPathComponent(name)
        guard mkfifo(url.path, 0o600) == 0 else { return nil }
        // O_RDWR, not O_RDONLY: holding a writer open ourselves keeps this
        // read end from ever seeing EOF just because the bridge has not
        // opened its own write end yet, matching `PaneControlChannel`.
        let descriptor = open(url.path, O_RDWR | O_NONBLOCK)
        guard descriptor >= 0 else {
            unlink(url.path)
            return nil
        }
        path = url.path
        fd = descriptor
    }

    deinit { close() }

    /// Starts reading status lines off the FIFO on `queue`: `paddock.
    /// mouse_capture` lines invoke `onCapture(enabled, sgrPixels)`, and the
    /// one-shot `paddock.first_frame` line invokes `onFirstFrame`, both in
    /// arrival order. The app passes `.main` so back-to-back capture lines
    /// (an app toggling mouse mode off then on) apply in the order the
    /// bridge wrote them, with no re-ordering hop in between. Guarded
    /// exactly like the bridge's own FIFO reader: a short read is not EOF,
    /// non-JSON and non-matching lines are skipped, and a single undecodable
    /// byte cannot stall the drain loop (lines are split as `Data`, decoded
    /// per line). The fd is closed by the source's cancel handler, never
    /// while an event handler may still be reading it.
    public func start(
        queue: DispatchQueue,
        onFirstFrame: @escaping @Sendable () -> Void = {},
        onHoldLost: @escaping @Sendable () -> Void = {},
        onCapture: @escaping @Sendable (Bool, Bool) -> Void
    ) {
        guard fd >= 0, source == nil else { return }
        let readFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: readFD, queue: queue)
        source.setEventHandler { [buffer] in
            var scratch = [UInt8](repeating: 0, count: 4096)
            let n = read(readFD, &scratch, scratch.count)
            guard n > 0 else { return }
            buffer.append(Data(scratch.prefix(n)))
            while let line = buffer.popLine() {
                if let (enabled, sgrPixels) = PaneStatusChannel.parseMouseCapture(line) {
                    onCapture(enabled, sgrPixels)
                    continue
                }
                if PaneStatusChannel.parseFirstFrame(line) {
                    onFirstFrame()
                    continue
                }
                if PaneStatusChannel.parseHoldLost(line) {
                    onHoldLost()
                }
            }
        }
        source.setCancelHandler { Foundation.close(readFD) }
        source.resume()
        self.source = source
    }

    /// `(enabled, sgrPixels)` for a well-formed `paddock.mouse_capture` line,
    /// nil for anything else. Pure, so the parse is testable without a FIFO.
    public static func parseMouseCapture(_ line: Data) -> (Bool, Bool)? {
        guard
            let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            object["type"] as? String == "paddock.mouse_capture",
            let enabled = object["enabled"] as? Bool
        else { return nil }
        let sgrPixels = object["sgr_pixels"] as? Bool ?? false
        return (enabled, sgrPixels)
    }

    /// Whether a line is the bridge's one-shot `paddock.first_frame` status
    /// line. Pure, so the parse is testable without a FIFO.
    public static func parseFirstFrame(_ line: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return false }
        return object["type"] as? String == "paddock.first_frame"
    }

    /// Whether a line is the bridge's `paddock.hold_lost` status line: every
    /// retake was refused and none is pending, so the pane has no herdr client
    /// at all. Pure, so the parse is testable without a FIFO.
    public static func parseHoldLost(_ line: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return false }
        return object["type"] as? String == HoldStatus.lost.rawValue
    }

    /// Once started, the fd belongs to the source's cancel handler (see
    /// `start`); before that, it is closed here directly.
    public func close() {
        guard fd >= 0 else { return }
        if let source {
            source.cancel()
            self.source = nil
        } else {
            Foundation.close(fd)
        }
        fd = -1
        unlink(path)
    }
}

/// Splits a byte stream into newline-delimited records, internally locked so
/// the reader's serial handler and any future sharing stay safe. Records come
/// back as `Data`, not `String`, so one non-UTF-8 byte cannot stall the drain
/// loop -- the same contract as the bridge's own `BridgeLineBuffer`.
private final class StatusLineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(data)
    }

    func popLine() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard let newline = buffer.firstIndex(of: 0x0A) else { return nil }
        let line = Data(buffer[buffer.startIndex..<newline])
        buffer.removeSubrange(buffer.startIndex...newline)
        return line
    }
}
