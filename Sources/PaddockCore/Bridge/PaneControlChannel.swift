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
/// scrolling cannot ride that path. But unlike Herdglass, this type has NO
/// `scroll` API: herdr's pane scrollback is real, shared viewport state
/// mutated on the one ghostty terminal core object every reader of the pane
/// (a live TUI attach, an observe client, this bridge) shares -- there is no
/// per-client scroll offset anywhere in herdr's model (verified against
/// server source and live, spikes/08-control/findings.md Q3). Forwarding a
/// `terminal.scroll` here would move the pane out from under whoever else is
/// looking at it. Any in-surface scroll gesture must stay local to
/// libghostty's own scrollback (fed by the same `terminal.frame` bytes the
/// bridge already relays); `ControlBridge` additionally refuses to forward
/// `terminal.scroll` even if some other caller wrote one to the FIFO
/// directly, since the FIFO itself is plain text and not gated on this type.
/// The channel stays for other control message types a future surface may
/// need.
public final class PaneControlChannel {
    /// Environment variable the bridge reads the FIFO path from.
    public static let environmentKey = "HERDR_TERM_CONTROL_PIPE"

    public let path: String
    private var fd: Int32 = -1

    /// Returns nil when the FIFO cannot be made; the pane then simply has no
    /// control channel, which today costs nothing since there is no
    /// scroll-forwarding path to lose.
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

    public func close() {
        guard fd >= 0 else { return }
        Foundation.close(fd)
        fd = -1
        unlink(path)
    }
}
