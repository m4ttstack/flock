// Portions derived from Herdglass (BSL-1.1), Sources/HerdrClient/ControlBridge.swift.
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Everything the bridge needs, on its own argv: paddock's ghostty surface
/// hands the pane over as arguments baked into the command it configures,
/// because libghostty does not forward a surface's `env_vars`/`command`
/// through to its PTY child. The environment is still read as a fallback so
/// `--bridge` stays runnable by hand and so an older surface keeps working
/// against a newer bridge.
public struct BridgeOptions: Equatable, Sendable {
    public var target: String
    public var cols: Int?
    public var rows: Int?
    public var socketPath: String?
    public var herdrBinary: String?
    public var controlPipe: String?

    public init(arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) {
        var values: [String: String] = [:]
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let flag = arguments[index]
            guard flag.hasPrefix("--"), arguments.indices.contains(index + 1) else {
                index += 1
                continue
            }
            let value = arguments[index + 1]
            guard !value.hasPrefix("--") else {
                index += 1
                continue
            }
            values[flag] = value
            index += 2
        }

        func pick(_ flag: String, _ variable: String) -> String? {
            if let value = values[flag], !value.isEmpty { return value }
            if let value = environment[variable], !value.isEmpty { return value }
            return nil
        }

        target = pick("--bridge", "HERDR_TERM_TARGET") ?? ""
        cols = values["--cols"].flatMap(Int.init)
        rows = values["--rows"].flatMap(Int.init)
        socketPath = pick("--socket", "HERDR_SOCKET_PATH")
        herdrBinary = pick("--herdr-bin", "HERDR_BIN")
        controlPipe = pick("--control-pipe", PaneControlChannel.environmentKey)
    }

    /// The argv a ghostty surface configures libghostty to run for a pane.
    /// `--bridge <target>` first: unlike `herdr`'s own CLI (see
    /// `ControlBridge.run`'s comment on the subprocess argv order), this
    /// bridge's own flag parser tolerates either order, but leading with the
    /// target keeps the two argv shapes visually distinct at a glance.
    public static func argv(
        executablePath: String,
        target: String,
        cols: Int,
        rows: Int,
        socketPath: String,
        herdrBinary: String? = nil,
        controlPipe: String? = nil
    ) -> [String] {
        var argv = [
            executablePath, "--bridge", target,
            "--cols", "\(cols)", "--rows", "\(rows)",
            "--socket", socketPath,
        ]
        if let herdrBinary, !herdrBinary.isEmpty {
            argv += ["--herdr-bin", herdrBinary]
        }
        if let controlPipe, !controlPipe.isEmpty {
            argv += ["--control-pipe", controlPipe]
        }
        return argv
    }
}

/// A PTY's size in cells, the only size herdr deals in.
public struct PTYSize: Equatable, Sendable {
    public var cols: Int
    public var rows: Int

    public init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
    }
}

/// PTY child for libghostty: translates herdr `terminal session control`
/// NDJSON into raw bytes on stdout / keystrokes on stdin.
public enum ControlBridge {
    public static func run(arguments: [String] = Array(CommandLine.arguments.dropFirst())) {
        signal(SIGPIPE, SIG_IGN)
        setvbuf(stdout, nil, _IONBF, 0)
        setvbuf(stdin, nil, _IONBF, 0)

        let options = BridgeOptions(arguments: arguments)
        guard !options.target.isEmpty else {
            fputs("paddock-bridge: --bridge <pane> is required\n", stderr)
            exit(2)
        }
        guard let (executableURL, prefixArguments) = resolveHerdrBinary(explicit: options.herdrBinary) else {
            fputs("paddock-bridge: cannot locate herdr (set --herdr-bin/HERDR_BIN or add it to PATH)\n", stderr)
            exit(2)
        }

        let cookedTerminal = enterRawMode()
        var size = PTYSize(cols: options.cols ?? 0, rows: options.rows ?? 0)
        if size.cols <= 0 || size.rows <= 0 {
            let ioctlSize = currentWinSize(fd: STDIN_FILENO)
            if size.cols <= 0 { size.cols = ioctlSize.cols > 0 ? ioctlSize.cols : 80 }
            if size.rows <= 0 { size.rows = ioctlSize.rows > 0 ? ioctlSize.rows : 24 }
        }

        let proc = Process()
        proc.executableURL = executableURL
        // Target before flags: `--takeover` first mis-parses the target as
        // an unknown option (spikes/08-control/findings.md, surprise 1).
        // Takeover is always on: it only ever evicts a stale prior paddock
        // bridge on the same pane, never the ordinary herdr TUI (18d ruling,
        // same findings doc, Q1).
        proc.arguments = prefixArguments + [
            "terminal", "session", "control", options.target, "--takeover",
            "--cols", "\(size.cols)", "--rows", "\(size.rows)",
        ]
        var processEnv = ProcessInfo.processInfo.environment
        if let socket = options.socketPath { processEnv["HERDR_SOCKET_PATH"] = socket }
        proc.environment = processEnv

        let toHerdr = Pipe()
        let fromHerdr = Pipe()
        proc.standardInput = toHerdr
        proc.standardOutput = fromHerdr
        proc.standardError = FileHandle.standardError

        do {
            try proc.run()
        } catch {
            fputs("paddock-bridge: failed to spawn herdr: \(error)\n", stderr)
            exit(1)
        }

        let io = BridgeIO(herdrInFD: toHerdr.fileHandleForWriting.fileDescriptor) {
            if proc.isRunning { proc.terminate() }
        }
        io.startStdin()
        io.startWinch()
        // Read the size again now that the signal source exists, because the
        // one resize a pane cannot afford to miss is the one that lands here.
        // libghostty creates every surface at its own placeholder size and
        // only reports the real one once the surface's view has been laid
        // out, so a SIGWINCH delivered before the source is armed is gone for
        // good (SIGWINCH's default disposition discards it). A change earlier
        // than this read is caught by the read, a change later than it by
        // the source.
        if let resize = startupResize(spawned: size, current: currentWinSize(fd: STDIN_FILENO)) {
            io.send(["type": "terminal.resize", "cols": resize.cols, "rows": resize.rows])
        }
        io.startHerdrOutput(fromHerdr.fileHandleForReading)
        if let controlPipe = options.controlPipe {
            io.startControlPipe(at: controlPipe)
        }

        proc.waitUntilExit()
        io.close()
        if var cookedTerminal { tcsetattr(STDIN_FILENO, TCSAFLUSH, &cookedTerminal) }
        // Keep the pipes alive until herdr has fully exited.
        withExtendedLifetime(toHerdr) {}
        withExtendedLifetime(fromHerdr) {}
        exit(proc.terminationStatus == 0 ? 0 : max(Int32(proc.terminationStatus), 1))
    }

    /// The resize a starting bridge owes herdr, or nil when the PTY still has
    /// the size herdr was spawned with. See the call site for why a bridge is
    /// born owing one.
    public static func startupResize(spawned: PTYSize, current: PTYSize) -> PTYSize? {
        guard current.cols > 0, current.rows > 0, current != spawned else { return nil }
        return current
    }

    /// `nil` for anything that is not a well-formed `terminal.frame` line.
    /// A pure function so line-boundary handling (buffering a herdr line
    /// across several `read()`s) can be tested independently of decoding.
    static func decodeFrame(_ line: Data) -> Data? {
        guard !line.isEmpty,
              let frame = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              frame["type"] as? String == "terminal.frame",
              let encoded = frame["bytes"] as? String,
              let bytes = Data(base64Encoded: encoded),
              !bytes.isEmpty
        else { return nil }
        return bytes
    }

    /// The `terminal.input` object for a chunk of raw PTY bytes.
    static func encodeInput(_ bytes: Data) -> [String: Any] {
        ["type": "terminal.input", "bytes": bytes.base64EncodedString()]
    }

    /// `nil` for anything that is not a well-formed, forwardable `terminal.*`
    /// control command read off the FIFO. `terminal.scroll` is excluded even
    /// though it would otherwise be well-formed: unlike every other
    /// `terminal.*` message, scroll mutates the pane's one shared viewport,
    /// read by every other client of that pane, not a per-client offset
    /// (verified against herdr's server source and live, spikes/08-control/
    /// findings.md Q3) -- forwarding it here would move Matt's real pane out
    /// from under him. This filter is the enforcement point; the FIFO itself
    /// is plain text any process could write to, and `PaneControlChannel`
    /// deliberately has no API that would construct a scroll command.
    static func parseForwardableControlCommand(_ line: Data) -> [String: Any]? {
        guard
            let command = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            let type = command["type"] as? String,
            type.hasPrefix("terminal."),
            type != "terminal.scroll"
        else { return nil }
        return command
    }

    /// The NDJSON line for one control-channel object, or nil if it cannot
    /// be encoded.
    static func encodeLine(_ object: [String: Any]) -> Data? {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        var payload = data
        payload.append(0x0A)
        return payload
    }
}

/// libghostty hands the bridge a *cooked* PTY, which is wrong in every way
/// for a pane whose keyboard lives on another machine: `icanon` holds
/// keystrokes until Enter so a TUI never sees an arrow key, `echo` paints
/// them locally on top of herdr's frames, and `isig` turns ^C into a signal
/// that kills the bridge instead of a byte for the program in the pane.
/// `cfmakeraw` is only valid on a real tty: the guard on `isatty` is load
/// bearing for standalone/test invocations where stdin is a pipe, not a
/// PTY, and must return nil (skip raw-mode entirely) rather than let
/// `tcgetattr`/`tcsetattr` fail into undefined terminal state. Returns the
/// previous settings so they can be put back.
private func enterRawMode() -> termios? {
    var original = termios()
    guard isatty(STDIN_FILENO) == 1, tcgetattr(STDIN_FILENO, &original) == 0 else { return nil }
    var raw = original
    cfmakeraw(&raw)
    guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) == 0 else { return nil }
    return original
}

/// `fd` not a tty (no controlling terminal, as in this sandbox and in every
/// unit test here) reports a zero winsize rather than failing; every caller
/// already treats zero as "no answer yet" and falls back accordingly.
private func currentWinSize(fd: Int32) -> PTYSize {
    var ws = winsize()
    _ = ioctl(fd, TIOCGWINSZ, &ws)
    return PTYSize(cols: Int(ws.ws_col), rows: Int(ws.ws_row))
}

/// `herdrBinary` explicit (from `--herdr-bin`/`HERDR_BIN`, already resolved
/// into `BridgeOptions`) wins; otherwise a bare `herdr` found on `PATH` is
/// run through `/usr/bin/env`, since `Process.executableURL` needs a real
/// path and will not search `PATH` itself. Mirrors `ObserveSupervisor`'s own
/// resolution so the two herdr-spawning paths in paddock agree, rather than
/// porting Herdglass's separate SSH-oriented `HerdrPaths` (paddock has no
/// remote/SSH concept to serve).
private func resolveHerdrBinary(explicit: String?) -> (URL, [String])? {
    if let explicit, !explicit.isEmpty {
        return (URL(fileURLWithPath: explicit), [])
    }
    guard pathHasHerdr() else { return nil }
    return (URL(fileURLWithPath: "/usr/bin/env"), ["herdr"])
}

private func pathHasHerdr() -> Bool {
    guard let path = ProcessInfo.processInfo.environment["PATH"] else { return false }
    return path.split(separator: ":").contains { segment in
        FileManager.default.isExecutableFile(atPath: "\(segment)/herdr")
    }
}

/// Writes every byte, tolerating a reader that has already gone away.
/// Requires `SIGPIPE` to be ignored process-wide (`ControlBridge.run` does
/// this before any of these are reachable).
func writeIgnoringBrokenPipe(_ fd: Int32, _ data: Data) {
    data.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        var sent = 0
        while sent < raw.count {
            let n = write(fd, base.advanced(by: sent), raw.count - sent)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return }
            sent += n
        }
    }
}

/// Reads every available byte off `fd`, retrying a `read()` interrupted by
/// an unrelated signal (`EINTR`) instead of treating it as EOF. Herdglass's
/// original bridge did not retry here, which meant any signal delivered
/// while a read was blocked (SIGWINCH included, since GCD's signal source
/// and classic signal delivery both observe the same process-wide
/// disposition) could tear down the whole pane connection on a transient
/// interrupt rather than the reader actually going away. Returns `nil` on
/// genuine EOF/error, the (always non-empty) bytes read otherwise.
private func readAvailable(_ fd: Int32, into buffer: inout [UInt8]) -> Data? {
    while true {
        let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if n < 0 && errno == EINTR { continue }
        guard n > 0 else { return nil }
        return Data(buffer.prefix(n))
    }
}

/// The bridge's I/O translation, decoupled from `Process`/`FileHandle` via
/// injected file descriptors and an `onPeerGone` callback so it can be
/// driven over plain pipes in tests, with no real herdr child or real tty
/// required. `stdinFD`/`stdoutFD` default to the process's real stdin/
/// stdout for production use.
///
/// `@unchecked Sendable`: `herdrInFD`/`stdinFD`/`stdoutFD`/`onPeerGone` are
/// immutable after init. `closed` is read and written only inside
/// `writeLock`. `herdrOutputLines` is its own internally-locked buffer.
/// `stdinSource`/`winchSource`/`controlSource` are each written exactly once,
/// by `startStdin`/`startWinch`/`startControlPipe`, all called synchronously
/// from `ControlBridge.run` before any of the sources are resumed and so
/// before any of their event handlers can run; `close()` only ever runs
/// after `run`'s `proc.waitUntilExit()`, i.e. strictly after every `start*`
/// call has returned.
final class BridgeIO: @unchecked Sendable {
    private let herdrInFD: Int32
    private let stdinFD: Int32
    private let stdoutFD: Int32
    private let onPeerGone: () -> Void
    private let writeLock = NSLock()
    private let herdrOutputLines = BridgeLineBuffer()
    private var stdinSource: DispatchSourceRead?
    private var winchSource: DispatchSourceSignal?
    private var controlSource: DispatchSourceRead?
    private var closed = false

    init(herdrInFD: Int32, stdinFD: Int32 = STDIN_FILENO, stdoutFD: Int32 = STDOUT_FILENO, onPeerGone: @escaping () -> Void) {
        self.herdrInFD = herdrInFD
        self.stdinFD = stdinFD
        self.stdoutFD = stdoutFD
        self.onPeerGone = onPeerGone
    }

    func close() {
        writeLock.lock()
        closed = true
        writeLock.unlock()
        stdinSource?.cancel()
        winchSource?.cancel()
        controlSource?.cancel()
    }

    func send(_ object: [String: Any]) {
        guard let payload = ControlBridge.encodeLine(object) else { return }
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !closed else { return }
        writeIgnoringBrokenPipe(herdrInFD, payload)
    }

    func startStdin() {
        let fd = stdinFD
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInteractive))
        source.setEventHandler { [self] in
            var buffer = [UInt8](repeating: 0, count: 4096)
            guard let data = readAvailable(fd, into: &buffer) else {
                send(["type": "terminal.release"])
                source.cancel()
                onPeerGone()
                return
            }
            send(ControlBridge.encodeInput(data))
        }
        source.resume()
        stdinSource = source
    }

    /// Commands the surface cannot express as keystrokes. Forwarded to
    /// `send` verbatim EXCEPT `terminal.scroll`, filtered by
    /// `ControlBridge.parseForwardableControlCommand` -- see its doc comment.
    func startControlPipe(at path: String) {
        // O_RDWR mirrors the GUI side: neither end may ever see EOF just
        // because the other is idle.
        let fd = open(path, O_RDWR | O_NONBLOCK)
        guard fd >= 0 else {
            fputs("paddock-bridge: cannot open control pipe \(path)\n", stderr)
            return
        }
        startControlPipe(fd: fd, closeOnCancel: true)
    }

    /// Split from `startControlPipe(at:)` so tests can drive the read/filter/
    /// forward logic over a plain anonymous pipe, with no real FIFO needed.
    func startControlPipe(fd: Int32, closeOnCancel: Bool) {
        let commands = BridgeLineBuffer()
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInteractive))
        source.setEventHandler { [self] in
            var buffer = [UInt8](repeating: 0, count: 4096)
            let n = read(fd, &buffer, buffer.count)
            guard n > 0 else { return }
            commands.append(Data(buffer.prefix(n)))
            while let line = commands.popLine() {
                guard let command = ControlBridge.parseForwardableControlCommand(line) else { continue }
                send(command)
            }
        }
        if closeOnCancel {
            // Qualified: unqualified `close` here resolves to `BridgeIO`'s
            // own `close()` method, not the POSIX global.
            source.setCancelHandler { Foundation.close(fd) }
        }
        source.resume()
        controlSource = source
    }

    func startWinch() {
        let fd = stdinFD
        signal(SIGWINCH, SIG_IGN)
        let winch = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .global(qos: .userInteractive))
        winch.setEventHandler { [self] in
            let ws = currentWinSize(fd: fd)
            guard ws.cols > 0, ws.rows > 0 else { return }
            send(["type": "terminal.resize", "cols": ws.cols, "rows": ws.rows])
        }
        winch.resume()
        winchSource = winch
    }

    func startHerdrOutput(_ herdrOut: FileHandle) {
        herdrOut.readabilityHandler = { [self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                onPeerGone()
                return
            }
            herdrOutputLines.append(data)
            while let line = herdrOutputLines.popLine() {
                guard let bytes = ControlBridge.decodeFrame(line) else { continue }
                writeIgnoringBrokenPipe(stdoutFD, bytes)
            }
        }
    }
}

/// Splits a byte stream into newline-delimited records. Shared by
/// `BridgeIO`'s two independent fd-reading loops (herdr's stdout, the FIFO
/// control pipe); records come back as `Data`, not `String`, so a single
/// non-UTF-8 byte in one line cannot stall the drain loop
/// (`while let line = buffer.popLine()`) behind an undecodable record.
private final class BridgeLineBuffer: @unchecked Sendable {
    private var buffer = Data()

    func append(_ data: Data) {
        buffer.append(data)
    }

    func popLine() -> Data? {
        guard let newline = buffer.firstIndex(of: 0x0A) else { return nil }
        let line = Data(buffer[buffer.startIndex..<newline])
        buffer.removeSubrange(buffer.startIndex...newline)
        return line
    }
}
