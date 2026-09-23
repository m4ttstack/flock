// Portions derived from Herdglass (BSL-1.1), Sources/HerdrClient/PaneControlChannel.swift.
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Out-of-band GUI -> bridge channel, one FIFO per attached pane.
///
/// Everything the surface writes to the bridge's stdin becomes
/// `terminal.input`, which herdr hands straight to the program in the pane;
/// scrolling cannot ride that path. herdr's pane scrollback is real, shared
/// viewport state mutated on the one ghostty terminal core object every
/// reader of the pane (a live TUI attach, an observe client, this bridge)
/// shares -- there is no per-client scroll offset anywhere in herdr's model,
/// so a `terminal.scroll` sent here moves the pane's REAL viewport, the way
/// herdr's own TUI and Herdglass move it. `scroll(direction:lines:source:)`
/// is the one place this type ever constructs one; the resolved-focused
/// pane's wheel is the only caller (`GhosttySession.sendPaneScroll`), gated
/// upstream by `MouseForwarding.decide` dropping every mouse event for an
/// unfocused pane before a scroll command could ever be built.
///
/// A paste cannot ride the PTY either, for a different reason: it has to reach
/// herdr as one intact run of bytes, and the PTY neither preserves the escape
/// bytes that frame it nor keeps it in one piece (see `paste(_:)`).
public final class PaneControlChannel {
    /// Environment variable the bridge reads the FIFO path from.
    public static let environmentKey = "HERDR_TERM_CONTROL_PIPE"

    /// Wire values for `terminal.scroll`'s `direction` field
    /// (`src/client/terminal_sessions.rs`'s `TerminalControlScrollDirection`):
    /// herdr only ever moves the shared viewport vertically.
    public enum ScrollDirection: String, Equatable, Sendable {
        case up
        case down
    }

    /// Wire values for `terminal.scroll`'s `source` field. Flock only ever
    /// sends `.wheel` today; `.pageKey` is kept for a future keyboard
    /// scroll-through-herdr affordance that would want the same command
    /// shape.
    public enum ScrollSource: String, Equatable, Sendable {
        case wheel
        case pageKey = "page_key"
    }

    public let path: String
    private var fd: Int32 = -1

    /// Returns nil when the FIFO cannot be made; the pane's bridge then never
    /// hears a mouse or scroll command. `GhosttyControlSurfaceFactory` logs
    /// this failure rather than degrading silently.
    public init?(directory: URL = ScratchDirectory.url) {
        let name = "flock-\(UUID().uuidString.prefix(8)).ctl"
        let url = directory.appendingPathComponent(name)
        guard mkfifo(url.path, 0o600) == 0 else { return nil }
        // O_RDWR, not O_WRONLY: the bridge has not opened its end yet, and a
        // write-only open of a readerless FIFO fails with ENXIO. Holding the
        // read end open also keeps the bridge from seeing EOF whenever the
        // GUI happens to have nothing to say.
        let descriptor = open(url.path, O_RDWR | O_NONBLOCK)
        guard descriptor >= 0 else {
            unlink(url.path)
            return nil
        }
        path = url.path
        fd = descriptor
    }

    deinit { close() }

    public func send(_ command: [String: Any]) {
        guard fd >= 0, let payload = ControlBridge.encodeLine(command) else { return }
        writeWholeLine(payload)
    }

    /// How long a write waits for the bridge to drain the FIFO before giving
    /// up. Only a bridge that has stopped reading can reach it, and this runs
    /// on the main actor, so it bounds a stall behind an already dead pane
    /// rather than budgeting anything a working one spends.
    private static let drainTimeout: TimeInterval = 2

    /// The descriptor is non-blocking, so a line longer than the FIFO's buffer
    /// comes back `EAGAIN` partway through. Stopping there would leave half a
    /// line in the FIFO, and the bridge splits on newlines: the remainder would
    /// fuse with whatever command came next and take that one down with it.
    private func writeWholeLine(_ payload: Data) {
        let deadline = Date().addingTimeInterval(Self.drainTimeout)
        payload.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                let written = write(fd, base.advanced(by: sent), raw.count - sent)
                if written > 0 {
                    sent += written
                    continue
                }
                if written < 0, errno == EINTR { continue }
                guard written < 0, errno == EAGAIN else { return }
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { return }
                var writable = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                _ = poll(&writable, 1, Int32(remaining * 1000))
            }
        }
    }

    /// A `terminal.scroll` line: moves the pane's real, shared herdr
    /// viewport by `lines`. `lines` must be positive -- herdr drops (and
    /// this never even sends) a zero or negative line count -- since the
    /// caller's `ScrollAccumulator` already turns a wheel event into whole,
    /// signed cell steps and never invokes this for a zero-step tick.
    public func scroll(direction: ScrollDirection, lines: Int, source: ScrollSource = .wheel) {
        guard lines > 0 else { return }
        send([
            "type": "terminal.scroll",
            "direction": direction.rawValue,
            "lines": lines,
            "source": source.rawValue,
        ])
    }

    /// One `terminal.input` line carrying exactly one complete bracketed
    /// paste, which is the only shape herdr reads as a paste rather than as
    /// typed input (`src/server/pane_input.rs`'s
    /// `apply_terminal_attach_input`). herdr then re-frames it only for a pane
    /// whose own terminal asked for bracketed paste, so a frame sent from here
    /// is right whichever way the program in the pane has it set.
    ///
    /// This channel, never the surface's PTY: libghostty's text entry point
    /// replaces every ESC byte with a space before it writes
    /// (`Vendor/ghostty/src/input/paste.zig`), and it writes a frame's three
    /// pieces as three separate PTY writes, either of which leaves herdr
    /// reading something that is not one complete bracketed paste.
    public func paste(_ text: String) {
        guard let payload = BracketedPaste.payload(text) else { return }
        send(["type": "terminal.input", "bytes": payload.base64EncodedString()])
    }

    /// A hold command. Unlike everything else on this channel these are acted
    /// on by the bridge itself rather than forwarded to herdr, which is why
    /// they are `flock.`-namespaced (see `HoldCommand`).
    public func hold(_ command: HoldCommand) {
        send(command.json)
    }

    /// Tells the bridge this pane's surface just took a new grid, so it
    /// relays the PTY's size (see `ControlBridge.sizeSyncCommandType`). Sent
    /// on a real grid change only, and carrying no size: what reaches herdr
    /// is whatever the PTY itself has by then.
    public func syncSize() {
        send(["type": ControlBridge.sizeSyncCommandType])
    }

    public func close() {
        guard fd >= 0 else { return }
        Foundation.close(fd)
        fd = -1
        unlink(path)
    }
}
