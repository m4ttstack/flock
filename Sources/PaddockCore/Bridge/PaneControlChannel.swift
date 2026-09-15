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

    /// Wire values for `terminal.scroll`'s `source` field. Paddock only ever
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
    public init?(directory: URL = FileManager.default.temporaryDirectory) {
        let name = "paddock-\(UUID().uuidString.prefix(8)).ctl"
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
        writeIgnoringBrokenPipe(fd, payload)
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

    public func close() {
        guard fd >= 0 else { return }
        Foundation.close(fd)
        fd = -1
        unlink(path)
    }
}
