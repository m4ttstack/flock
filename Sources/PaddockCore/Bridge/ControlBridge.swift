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
    public var socketPath: String?
    public var herdrBinary: String?
    public var controlPipe: String?
    public var statusPipe: String?

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
        socketPath = pick("--socket", "HERDR_SOCKET_PATH")
        herdrBinary = pick("--herdr-bin", "HERDR_BIN")
        controlPipe = pick("--control-pipe", PaneControlChannel.environmentKey)
        statusPipe = pick("--status-pipe", PaneStatusChannel.environmentKey)
    }

    /// The argv a ghostty surface configures libghostty to run for a pane.
    /// `--bridge <target>` first: unlike `herdr`'s own CLI (see
    /// `ControlBridge.run`'s comment on the subprocess argv order), this
    /// bridge's own flag parser tolerates either order, but leading with the
    /// target keeps the two argv shapes visually distinct at a glance.
    public static func argv(
        executablePath: String,
        target: String,
        socketPath: String,
        herdrBinary: String? = nil,
        controlPipe: String? = nil,
        statusPipe: String? = nil
    ) -> [String] {
        var argv = [executablePath, "--bridge", target, "--socket", socketPath]
        if let herdrBinary, !herdrBinary.isEmpty {
            argv += ["--herdr-bin", herdrBinary]
        }
        if let controlPipe, !controlPipe.isEmpty {
            argv += ["--control-pipe", controlPipe]
        }
        if let statusPipe, !statusPipe.isEmpty {
            argv += ["--status-pipe", statusPipe]
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

/// PTY child for libghostty: translates a herdr `terminal session control`
/// NDJSON stream into raw bytes on stdout / keystrokes on stdin, and resizes
/// that pane's real runtime to its PTY's own size.
///
/// Every visible pane holds one of these for its whole life (Herdglass's
/// model): there is no observe verb and no live mode switch. Which pane
/// actually receives input is the GUI's business -- AppKit gives exactly one
/// view first-responder status, and `InputSinkDisposition` gates it on the
/// resolved focus besides.
public enum ControlBridge {
    /// Clear screen + cursor home, written to the pty as the bridge's very
    /// first bytes: a pane's ghostty surface is created once for its whole
    /// life, and on macOS its child always execs through `/usr/bin/login`
    /// (`Vendor/ghostty/src/termio/Exec.zig` `execCommand`'s darwin branch,
    /// unconditional for both `.shell` and `.direct` commands whenever the
    /// passwd lookup for the running uid succeeds), which writes its own
    /// "Last login: ..." banner straight into the pty before this process
    /// even starts. No config key, `command =` spelling, or env var in that
    /// darwin branch skips the wrap, so this is the only reachable point at
    /// which paddock ever sees the pty: wiping it before the first real
    /// `terminal.frame` arrives bounds the banner's visible lifetime to a
    /// single paint, once per pane, no matter how long login/exec take
    /// upstream.
    static let startupClearScreen = Data("\u{1B}[2J\u{1B}[H".utf8)

    /// Split out so a test can drive it over a plain pipe fd instead of the
    /// process's real `STDOUT_FILENO`.
    static func writeStartupClearScreen(to fd: Int32) {
        writeIgnoringBrokenPipe(fd, startupClearScreen)
    }

    /// The herdr child argv at `cols`x`rows`. `--takeover` is unconditional:
    /// it only ever evicts a stale prior paddock bridge on the SAME pane (the
    /// ordinary herdr TUI is a separate client mode takeover cannot touch).
    static func childArgv(target: String, cols: Int, rows: Int) -> [String] {
        [
            "terminal", "session", "control", target, "--takeover",
            "--cols", "\(cols)", "--rows", "\(rows)",
        ]
    }

    public static func run(arguments: [String] = Array(CommandLine.arguments.dropFirst())) {
        signal(SIGPIPE, SIG_IGN)
        // Before anything else touches stdout, including `setvbuf` below:
        // every microsecond this waits is a microsecond longer the login
        // banner sits alone on the pane.
        writeStartupClearScreen(to: STDOUT_FILENO)
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
        // herdr starts at the PTY's size, the grid libghostty parses frames
        // into; 80x24 only covers a run with no tty behind it.
        var size = currentWinSize(fd: STDIN_FILENO)
        if size.cols <= 0 { size.cols = 80 }
        if size.rows <= 0 { size.rows = 24 }

        let proc = Process()
        proc.executableURL = executableURL
        // Target before flags: herdr's CLI mis-parses a leading `--takeover`
        // as an unknown option.
        proc.arguments = prefixArguments + childArgv(target: options.target, cols: size.cols, rows: size.rows)
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

        // The app holds this FIFO's read end open (`PaneStatusChannel`), so
        // O_RDWR|O_NONBLOCK never blocks and never sees EOF; -1 (no pipe, or
        // it could not be opened) simply disables capture relaying, degrading
        // to the pre-passthrough selection-only behavior.
        let statusFD: Int32 = options.statusPipe.map { open($0, O_RDWR | O_NONBLOCK) } ?? -1
        if let statusPipe = options.statusPipe, statusFD < 0 {
            fputs("paddock-bridge: cannot open status pipe \(statusPipe)\n", stderr)
        }

        let owner = BridgeChildOwner(process: proc)
        let io = BridgeIO(
            herdrInFD: toHerdr.fileHandleForWriting.fileDescriptor, statusFD: statusFD,
            spawnedSize: size, onPeerGone: { owner.terminate() }
        )

        io.startStdin()
        io.startWinch()
        // A SIGWINCH delivered before the source was armed is gone, and a new
        // surface's PTY is resized a moment after this process forks, so the
        // size is read once more now that nothing later can be missed.
        io.relayPTYSize()
        io.startHerdrOutput(fromHerdr.fileHandleForReading)
        if let controlPipe = options.controlPipe {
            io.startControlPipe(at: controlPipe)
        }

        proc.waitUntilExit()
        io.close()
        if statusFD >= 0 { Foundation.close(statusFD) }
        if var cookedTerminal { tcsetattr(STDIN_FILENO, TCSAFLUSH, &cookedTerminal) }
        let status = proc.terminationStatus
        exit(status == 0 ? 0 : max(Int32(status), 1))
    }

    /// `nil` for anything that is not a well-formed `terminal.frame` line.
    /// A pure function so line-boundary handling (buffering a herdr line
    /// across several `read()`s) can be tested independently of decoding.
    static func parseFrame(_ line: Data) -> HerdrFrame? {
        guard !line.isEmpty,
              let frame = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              frame["type"] as? String == "terminal.frame",
              let encoded = frame["bytes"] as? String,
              let bytes = Data(base64Encoded: encoded),
              !bytes.isEmpty
        else { return nil }
        return HerdrFrame(bytes: bytes, full: frame["full"] as? Bool ?? false)
    }

    /// The `terminal.input` object for a chunk of raw PTY bytes.
    static func encodeInput(_ bytes: Data) -> [String: Any] {
        ["type": "terminal.input", "bytes": bytes.base64EncodedString()]
    }

    /// A `paddock.mouse_capture` NDJSON line for a herdr `terminal.mouse_capture`
    /// line, or nil for anything else. This is how the bridge relays the one
    /// piece of pane state its `terminal.frame` stream drops (herdr's screen
    /// repaint never carries the mouse DECSET) out to the app on the status
    /// FIFO. Paddock-namespaced so it can never be mistaken for a forwardable
    /// `terminal.*` command. A pure function so the parse is testable.
    static func encodeMouseCaptureStatus(_ line: Data) -> Data? {
        guard
            let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            object["type"] as? String == "terminal.mouse_capture",
            let enabled = object["enabled"] as? Bool
        else { return nil }
        let sgrPixels = object["sgr_pixels"] as? Bool ?? false
        return encodeLine([
            "type": "paddock.mouse_capture",
            "enabled": enabled,
            "sgr_pixels": sgrPixels,
        ])
    }

    /// `nil` for anything that is not a well-formed, forwardable `terminal.*`
    /// control command read off the FIFO. Every `terminal.*` type forwards
    /// verbatim, `terminal.scroll` included: it mutates the pane's one
    /// shared herdr viewport, but that is the intended effect -- wheel scroll
    /// moves the real pane the way herdr's own TUI and Herdglass move it. The
    /// FIFO only ever carries one for the resolved-focused pane in the first
    /// place: `MouseForwarding.decide` drops every mouse event for an
    /// unfocused pane before a `terminal.scroll` could ever be built (see
    /// `PaneControlChannel.scroll`). `terminal.resize` is refused: a size
    /// reaches herdr only from the PTY itself (`BridgeIO.startWinch`).
    static func parseForwardableControlCommand(_ line: Data) -> [String: Any]? {
        guard
            let command = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            let type = command["type"] as? String,
            type.hasPrefix("terminal."),
            type != "terminal.resize"
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

/// One herdr `terminal.frame` line, decoded: the ANSI bytes, and whether they
/// redraw every cell rather than diff against the previous frame.
struct HerdrFrame: Equatable, Sendable {
    let bytes: Data
    let full: Bool
}

/// Which PTY winsizes become a `terminal.resize`: every readable size herdr
/// was not already given, starting from the size its child was spawned at.
/// Pure, so the dedupe and the startup read are testable without a signal.
struct PTYResizeRelay: Equatable, Sendable {
    private(set) var herdrSize: PTYSize?

    init(spawned: PTYSize?) {
        herdrSize = spawned
    }

    /// The size to send herdr for the PTY's current `winsize`, or nil when it
    /// is unreadable or herdr already has it.
    mutating func relay(_ winsize: PTYSize?) -> PTYSize? {
        guard let winsize, winsize.cols > 0, winsize.rows > 0, winsize != herdrSize else { return nil }
        herdrSize = winsize
        return winsize
    }
}

/// The bridge's one herdr child, terminated exactly once.
///
/// `@unchecked Sendable`: `terminated` is read and written only inside
/// `lock`; `process` is immutable after init.
final class BridgeChildOwner: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private var terminated = false

    init(process: Process) {
        self.process = process
    }

    /// `Process.terminate()` raises on a task that was never launched, so the
    /// `isRunning` check is what keeps this callable before a spawn.
    func terminate() {
        lock.lock()
        defer { lock.unlock() }
        guard !terminated else { return }
        terminated = true
        guard process.isRunning else { return }
        terminateWithBoundedEscalation(process)
    }
}

/// SIGTERM, then a bounded synchronous wait, then SIGKILL if the child is
/// still alive. A herdr child that ignores SIGTERM would otherwise leave
/// `ControlBridge.run` blocked in `waitUntilExit()` forever, holding the
/// pane's attach-owner entry and its resize lock against every other client.
/// Blocks whichever DispatchSource queue delivered the peer-gone event, never
/// the main actor.
func terminateWithBoundedEscalation(_ process: Process, timeout: TimeInterval = 0.3) {
    process.terminate()
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning, Date() < deadline {
        usleep(10_000)
    }
    if process.isRunning {
        kill(process.processIdentifier, SIGKILL)
    }
}

/// libghostty hands the bridge a *cooked* PTY, which is wrong in every way
/// for a pane whose keyboard lives on another machine: `icanon` holds
/// keystrokes until Enter so a TUI never sees an arrow key, `echo` paints
/// them locally on top of herdr's frames, and `isig` turns ^C into a signal
/// that kills the bridge instead of a byte for the program in the pane.
/// `cfmakeraw` is only valid on a real tty: the guard on `isatty` matters for
/// standalone/test invocations where stdin is a pipe, not a PTY, and must
/// return nil (skip raw-mode entirely) rather than let `tcgetattr`/`tcsetattr`
/// fail into undefined terminal state. Returns the previous settings so they
/// can be put back.
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
/// path and will not search `PATH` itself.
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
/// `@unchecked Sendable`: `stdinFD`/`stdoutFD`/`onPeerGone` are immutable
/// after init. `herdrInFD`/`closed` are read and written only inside
/// `writeLock`. `herdrOutputGeneration` and every write to `stdoutFD` are
/// guarded by `stdoutLock` (see `startHerdrOutput`'s own doc for why a
/// separate lock from `writeLock` is needed). `stdinSource`/`controlSource`
/// are each written exactly once, by `startStdin`/`startControlPipe`, both
/// called synchronously from `ControlBridge.run` before any of the sources
/// are resumed and so before any of their event handlers can run; `close()`
/// only ever runs after `run`'s wait, i.e. strictly after every `start*` call
/// has returned. `winchSource` is written once, by `startWinch`, under the
/// same invariant. `resizeRelay` is read and written only inside
/// `resizeLock`, which is held across the resize it emits.
final class BridgeIO: @unchecked Sendable {
    private var herdrInFD: Int32
    private let stdinFD: Int32
    private let stdoutFD: Int32
    /// The bridge -> app status FIFO (`--status-pipe`), write-only from here,
    /// or -1 when no status pipe was configured. Written under `stdoutLock`
    /// alongside the frame writes.
    private let statusFD: Int32
    private let onPeerGone: () -> Void
    private let writeLock = NSLock()
    /// Guards `stdoutFD` writes AND `herdrOutputGeneration` together (see
    /// `startHerdrOutput`): every write checks the generation it was
    /// installed under is still current, atomically with the write itself.
    private let stdoutLock = NSLock()
    private var herdrOutputGeneration = 0
    /// Latches true the first time a full-redraw `terminal.frame` is written
    /// to the PTY, for this bridge process's WHOLE life -- herdr repaints in
    /// full on every resize, and the app only needs to know once, ever, that
    /// this pane has real content. Guarded by `stdoutLock` alongside the frame
    /// write it is decided next to.
    private var firstFrameSent = false
    private var stdinSource: DispatchSourceRead?
    private var controlSource: DispatchSourceRead?
    private var winchSource: DispatchSourceSignal?
    private var closed = false
    /// Held across a relay decision AND the resize it sends, so two sizes
    /// decided on different queues reach herdr in the order they were read.
    private let resizeLock = NSLock()
    private var resizeRelay: PTYResizeRelay
    /// The PTY winsize; nil when it cannot be read.
    private let ptySize: () -> PTYSize?

    init(
        herdrInFD: Int32, stdinFD: Int32 = STDIN_FILENO, stdoutFD: Int32 = STDOUT_FILENO,
        statusFD: Int32 = -1, spawnedSize: PTYSize? = nil, ptySize: (() -> PTYSize?)? = nil,
        onPeerGone: @escaping () -> Void
    ) {
        self.herdrInFD = herdrInFD
        self.stdinFD = stdinFD
        self.stdoutFD = stdoutFD
        self.statusFD = statusFD
        self.resizeRelay = PTYResizeRelay(spawned: spawnedSize)
        self.ptySize = ptySize ?? {
            let size = currentWinSize(fd: stdinFD)
            return size.cols > 0 && size.rows > 0 ? size : nil
        }
        self.onPeerGone = onPeerGone
    }

    func close() {
        writeLock.lock()
        closed = true
        writeLock.unlock()
        stdinSource?.cancel()
        controlSource?.cancel()
        winchSource?.cancel()
    }

    /// libghostty sets the PTY winsize only when it applies a new grid to its
    /// terminal, so a resize sent from here reaches herdr after the surface
    /// can take the full frame herdr answers it with. A size sent any earlier
    /// lands that frame in the old grid.
    func startWinch() {
        signal(SIGWINCH, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .global(qos: .userInteractive))
        source.setEventHandler { [weak self] in
            self?.relayPTYSize()
        }
        source.resume()
        winchSource = source
    }

    /// Sends herdr the PTY's current size unless herdr already has it.
    func relayPTYSize() {
        resizeLock.lock()
        defer { resizeLock.unlock() }
        guard let size = resizeRelay.relay(ptySize()) else { return }
        send(["type": "terminal.resize", "cols": size.cols, "rows": size.rows])
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

    /// Commands the surface cannot express as keystrokes, forwarded verbatim
    /// -- see `ControlBridge.parseForwardableControlCommand`'s doc comment.
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

    /// A fresh `BridgeLineBuffer`, scoped to one herdr output handle, per
    /// call, and a bumped generation captured by this closure: every write
    /// checks the generation is still current, atomically with the write,
    /// under `stdoutLock` (see that property's own doc) -- so a superseded
    /// handle's callback, however far into an already-started invocation it
    /// was, can write nothing once a newer generation exists, and cannot
    /// interleave with the current handle's own writes either.
    func startHerdrOutput(_ herdrOut: FileHandle) {
        let lines = BridgeLineBuffer()
        let generation: Int = {
            stdoutLock.lock()
            defer { stdoutLock.unlock() }
            herdrOutputGeneration += 1
            return herdrOutputGeneration
        }()
        herdrOut.readabilityHandler = { [self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                stdoutLock.lock()
                let stillCurrent = herdrOutputGeneration == generation
                stdoutLock.unlock()
                if stillCurrent { onPeerGone() }
                return
            }
            lines.append(data)
            while let line = lines.popLine() {
                if let frame = ControlBridge.parseFrame(line) {
                    stdoutLock.lock()
                    let stillCurrent = herdrOutputGeneration == generation
                    if stillCurrent { writeIgnoringBrokenPipe(stdoutFD, frame.bytes) }
                    var firstFrameLine: Data?
                    if stillCurrent, frame.full, !firstFrameSent, statusFD >= 0 {
                        firstFrameSent = true
                        firstFrameLine = ControlBridge.encodeLine(["type": "paddock.first_frame"])
                    }
                    stdoutLock.unlock()
                    if !stillCurrent { return }
                    if let firstFrameLine {
                        writeIgnoringBrokenPipe(statusFD, firstFrameLine)
                    }
                    continue
                }
                // The pane app toggled mouse reporting: relay it to the app on
                // the status FIFO.
                if statusFD >= 0, let statusLine = ControlBridge.encodeMouseCaptureStatus(line) {
                    stdoutLock.lock()
                    let stillCurrent = herdrOutputGeneration == generation
                    if stillCurrent { writeIgnoringBrokenPipe(statusFD, statusLine) }
                    stdoutLock.unlock()
                    if !stillCurrent { return }
                }
            }
        }
    }
}

/// Splits a byte stream into newline-delimited records. Shared by
/// `BridgeIO`'s two independent fd-reading loops (herdr's stdout, the FIFO
/// control pipe); records come back as `Data`, not `String`, so a single
/// non-UTF-8 byte in one line cannot stall the drain loop
/// (`while let line = buffer.popLine()`) behind an undecodable record.
/// Internally locked so an instance stays safe even if it is ever shared
/// beyond a single DispatchSource's serial handler.
private final class BridgeLineBuffer: @unchecked Sendable {
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
