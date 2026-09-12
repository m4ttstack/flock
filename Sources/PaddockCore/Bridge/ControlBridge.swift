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

/// Which herdr session verb the bridge's current child speaks. The pane's
/// ghostty surface, the PTY, and libghostty's own scrollback never change
/// across a mode switch -- only which verb is behind the bridge's pipes.
public enum PaneMode: String, Equatable, Sendable {
    case control
    case observe
}

/// PTY child for libghostty: translates a herdr `terminal session` NDJSON
/// stream into raw bytes on stdout / keystrokes on stdin, and switches that
/// child, live, between herdr's two session verbs on `paddock.mode`.
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
    /// upstream -- a later mode switch never re-execs `/usr/bin/login` (the
    /// bridge itself is not respawned, only its herdr child), so this only
    /// ever needs to run once.
    static let startupClearScreen = Data("\u{1B}[2J\u{1B}[H".utf8)

    /// Split out so a test can drive it over a plain pipe fd instead of the
    /// process's real `STDOUT_FILENO`.
    static func writeStartupClearScreen(to fd: Int32) {
        writeIgnoringBrokenPipe(fd, startupClearScreen)
    }

    /// The herdr child argv for `mode` at `cols`x`rows`. Takeover is always
    /// on for control mode (it only ever evicts a stale prior paddock bridge
    /// on the same pane; the ordinary herdr TUI is a separate client mode
    /// takeover cannot touch) -- observe mode carries no ownership to evict,
    /// so it takes no `--takeover` flag at all.
    static func childArgv(mode: PaneMode, target: String, cols: Int, rows: Int) -> [String] {
        switch mode {
        case .control:
            return [
                "terminal", "session", "control", target, "--takeover",
                "--cols", "\(cols)", "--rows", "\(rows)",
            ]
        case .observe:
            return [
                "terminal", "session", "observe", target,
                "--cols", "\(cols)", "--rows", "\(rows)",
            ]
        }
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
        var size = PTYSize(cols: options.cols ?? 0, rows: options.rows ?? 0)
        if size.cols <= 0 || size.rows <= 0 {
            let ioctlSize = currentWinSize(fd: STDIN_FILENO)
            if size.cols <= 0 { size.cols = ioctlSize.cols > 0 ? ioctlSize.cols : 80 }
            if size.rows <= 0 { size.rows = ioctlSize.rows > 0 ? ioctlSize.rows : 24 }
        }

        func spawnChild(mode: PaneMode, size: PTYSize) -> BridgeChild? {
            let proc = Process()
            proc.executableURL = executableURL
            // Target before flags: herdr's CLI mis-parses a leading
            // `--takeover` as an unknown option.
            proc.arguments = prefixArguments + childArgv(mode: mode, target: options.target, cols: size.cols, rows: size.rows)
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
                return nil
            }
            return BridgeChild(mode: mode, process: proc, toHerdrFD: toHerdr.fileHandleForWriting.fileDescriptor, fromHerdrHandle: fromHerdr.fileHandleForReading)
        }

        // A pane's bridge is born in OBSERVE mode unconditionally: whichever
        // pane is actually focused gets its `paddock.mode: control` line
        // moments later, over the FIFO, from `SessionViewModel`'s own
        // attach -- see `GhosttySession.setPaneMode`.
        guard let initialChild = spawnChild(mode: .observe, size: size) else {
            fputs("paddock-bridge: failed to spawn herdr: \n", stderr)
            exit(1)
        }

        let switcherBox = Box<BridgeModeSwitcher>()
        let io = BridgeIO(
            herdrInFD: initialChild.toHerdrFD, mode: .observe,
            onPeerGone: { switcherBox.value?.terminateCurrent() }
        )
        io.onModeCommand = { mode in switcherBox.value?.requestSwitch(to: mode) }
        io.onSizeChanged = { newSize in switcherBox.value?.recordSize(newSize) }

        let switcher = BridgeModeSwitcher(
            initial: initialChild, size: size, io: io,
            spawnChild: spawnChild,
            terminateChild: { child in
                child.fromHerdrHandle.readabilityHandler = nil
                terminateWithBoundedEscalation(child.process)
            }
        )
        switcherBox.value = switcher

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
            switcher.recordSize(resize)
        }
        io.startHerdrOutput(initialChild.fromHerdrHandle)
        if let controlPipe = options.controlPipe {
            io.startControlPipe(at: controlPipe)
        }

        // Blocks on whichever child is current; a mode switch replaces it
        // out from under this loop (see `BridgeModeSwitcher.requestSwitch`),
        // so re-check identity before deciding the bridge itself should end
        // -- a stale wait waking up because the OLD (killed) child exited is
        // not the bridge's own end-of-life.
        while true {
            let proc = switcher.currentProcess
            proc.waitUntilExit()
            if switcher.currentProcess === proc { break }
        }
        io.close()
        if var cookedTerminal { tcsetattr(STDIN_FILENO, TCSAFLUSH, &cookedTerminal) }
        let status = switcher.currentProcess.terminationStatus
        exit(status == 0 ? 0 : max(Int32(status), 1))
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
    /// read by every other client of that pane, not a per-client offset;
    /// forwarding it here would move the user's real pane out
    /// from under them. This filter is the enforcement point; the FIFO itself
    /// is plain text any process could write to, and `PaneControlChannel`
    /// deliberately has no API that would construct a scroll command.
    /// `paddock.mode` lines never reach this function at all -- see
    /// `parseModeCommand` and `BridgeIO.startControlPipe`'s own dispatch.
    static func parseForwardableControlCommand(_ line: Data) -> [String: Any]? {
        guard
            let command = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            let type = command["type"] as? String,
            type.hasPrefix("terminal."),
            type != "terminal.scroll"
        else { return nil }
        return command
    }

    /// `nil` for anything that is not a well-formed `paddock.mode` command,
    /// INCLUDING a recognized shape whose `mode` value is neither
    /// `"control"` nor `"observe"` -- an unknown mode is ignored, not a crash
    /// or a reason to tear down the control-pipe loop. Paddock-namespaced
    /// (`paddock.` rather than `terminal.`) so it can never be mistaken for a
    /// forwardable line by `parseForwardableControlCommand` above.
    static func parseModeCommand(_ line: Data) -> PaneMode? {
        guard
            let command = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            command["type"] as? String == "paddock.mode",
            let mode = command["mode"] as? String
        else { return nil }
        return PaneMode(rawValue: mode)
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

/// One live herdr child: which verb it speaks, the process itself, and the
/// pipe ends `BridgeIO` reads/writes.
struct BridgeChild {
    let mode: PaneMode
    let process: Process
    let toHerdrFD: Int32
    let fromHerdrHandle: FileHandle
}

/// SIGTERM, then a bounded synchronous wait, then SIGKILL if the child is
/// still alive. Blocks (rather than detaching the wait) because a mode
/// switch must not spawn the replacement child until the pane it is about
/// to take over is actually free. Safe to call on a background queue (the
/// control-pipe's own), never
/// on the main actor.
func terminateWithBoundedEscalation(_ process: Process, timeout: TimeInterval = 0.3) {
    process.terminationHandler = nil
    process.terminate()
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning, Date() < deadline {
        usleep(10_000)
    }
    if process.isRunning {
        kill(process.processIdentifier, SIGKILL)
    }
}

/// Single-writer-then-read holder for a value with a genuine init-order
/// cycle (`BridgeIO`'s callbacks need to reach a `BridgeModeSwitcher` that
/// itself needs the already-constructed `BridgeIO`). Written exactly once,
/// synchronously, before any `BridgeIO` source is resumed; read only from
/// callbacks that cannot fire before that point.
final class Box<T>: @unchecked Sendable {
    var value: T?
}

/// Owns whichever herdr child is live right now and performs the live mode
/// switch (kill the old child, spawn the other verb at the same size,
/// re-point `BridgeIO` at the new pipes) `BridgeIO`'s control-pipe reader
/// requests. Spawn and terminate are injected so this is unit-testable
/// without a real herdr binary or child process.
///
/// `@unchecked Sendable`: every stored var is read and written only inside
/// `lock`; `io`/`spawnChild`/`terminateChild` are immutable after init.
final class BridgeModeSwitcher: @unchecked Sendable {
    private let lock = NSLock()
    private var current: BridgeChild
    private var latestSize: PTYSize
    private let io: BridgeIO
    private let spawnChild: (PaneMode, PTYSize) -> BridgeChild?
    private let terminateChild: (BridgeChild) -> Void

    init(
        initial: BridgeChild, size: PTYSize, io: BridgeIO,
        spawnChild: @escaping (PaneMode, PTYSize) -> BridgeChild?,
        terminateChild: @escaping (BridgeChild) -> Void
    ) {
        self.current = initial
        self.latestSize = size
        self.io = io
        self.spawnChild = spawnChild
        self.terminateChild = terminateChild
    }

    var currentProcess: Process { lock.withLockHeld { current.process } }
    var currentMode: PaneMode { lock.withLockHeld { current.mode } }

    /// Updates the size the NEXT mode switch will spawn its replacement
    /// child at -- the latest SIGWINCH-observed size, not the size the
    /// bridge itself was started with.
    func recordSize(_ size: PTYSize) {
        lock.withLockHeld { latestSize = size }
    }

    /// Terminates the live child outright (the GUI tore the pane's surface
    /// down entirely, not a mode switch) -- wired to `BridgeIO`'s stdin-EOF
    /// path.
    func terminateCurrent() {
        let child = lock.withLockHeld { current }
        terminateChild(child)
    }

    /// Kills the current child and spawns `newMode` at the latest known
    /// size, then re-points `BridgeIO` at the new pipes -- a no-op if
    /// `newMode` already matches. Safe to call synchronously from
    /// `BridgeIO`'s control-pipe background queue: the bounded kill-wait
    /// blocks that queue, never the main actor. If the replacement fails to
    /// spawn, the bridge is left exactly as it was (old child already dead,
    /// `BridgeIO` untouched) rather than silently wedged on a mode no
    /// process backs -- a caller who cares can retry with another
    /// `paddock.mode` line.
    func requestSwitch(to newMode: PaneMode) {
        lock.lock()
        defer { lock.unlock() }
        guard newMode != current.mode else { return }
        let old = current
        let size = latestSize
        terminateChild(old)
        guard let next = spawnChild(newMode, size) else { return }
        current = next
        io.rewireHerdrChild(inFD: next.toHerdrFD, output: next.fromHerdrHandle)
        io.setMode(newMode)
    }
}

/// Mirrors `PaneTerminal.swift`'s own private helper of the same name.
private extension NSLock {
    func withLockHeld<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
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
/// after init. `herdrInFD`/`closed`/`mode`/`latestSize` are read and written
/// only inside `writeLock`. `herdrOutputLines` is its own internally-locked
/// buffer. `stdinSource`/`winchSource`/`controlSource` are each written
/// exactly once, by `startStdin`/`startWinch`/`startControlPipe`, all called
/// synchronously from `ControlBridge.run` before any of the sources are
/// resumed and so before any of their event handlers can run; `close()`
/// only ever runs after `run`'s wait loop, i.e. strictly after every
/// `start*` call has returned. `onModeCommand`/`onSizeChanged` are set once,
/// synchronously, before `startControlPipe`/`startWinch` resume their
/// sources, matching that same invariant.
final class BridgeIO: @unchecked Sendable {
    private var herdrInFD: Int32
    private let stdinFD: Int32
    private let stdoutFD: Int32
    private let onPeerGone: () -> Void
    private let writeLock = NSLock()
    private let herdrOutputLines = BridgeLineBuffer()
    private var stdinSource: DispatchSourceRead?
    private var winchSource: DispatchSourceSignal?
    private var controlSource: DispatchSourceRead?
    private var closed = false
    private var mode: PaneMode

    /// Fired when a `paddock.mode` line arrives on the control pipe --
    /// `ControlBridge.run` wires this to `BridgeModeSwitcher.requestSwitch`.
    /// Never invoked for anything else; a `paddock.mode` line is never
    /// forwarded to herdr regardless of whether this is set.
    var onModeCommand: ((PaneMode) -> Void)?
    /// Fired on every SIGWINCH-observed size change, so `BridgeModeSwitcher`
    /// always spawns a replacement child at the pane's real current size.
    var onSizeChanged: ((PTYSize) -> Void)?

    init(
        herdrInFD: Int32, stdinFD: Int32 = STDIN_FILENO, stdoutFD: Int32 = STDOUT_FILENO,
        mode: PaneMode = .observe, onPeerGone: @escaping () -> Void
    ) {
        self.herdrInFD = herdrInFD
        self.stdinFD = stdinFD
        self.stdoutFD = stdoutFD
        self.mode = mode
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

    /// Which verb this bridge's current child speaks. `startStdin`'s handler
    /// reads this on every stdin event to decide whether to forward.
    func setMode(_ newMode: PaneMode) {
        writeLock.lock()
        mode = newMode
        writeLock.unlock()
    }

    private func currentMode() -> PaneMode {
        writeLock.lock()
        defer { writeLock.unlock() }
        return mode
    }

    /// Re-points this `BridgeIO` at a NEW herdr child's pipes after a mode
    /// switch: the PTY (`stdinFD`/`stdoutFD`), the surface, and libghostty's
    /// own scrollback are all untouched -- only which process is behind
    /// `send`/`startHerdrOutput` changes. The caller (`BridgeModeSwitcher`)
    /// has already detached the OLD `fromHerdrHandle`'s readability handler
    /// before this runs, so re-arming `startHerdrOutput` here cannot race a
    /// stray EOF from the child this is replacing.
    func rewireHerdrChild(inFD: Int32, output: FileHandle) {
        writeLock.lock()
        herdrInFD = inFD
        writeLock.unlock()
        startHerdrOutput(output)
    }

    func startStdin() {
        let fd = stdinFD
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInteractive))
        source.setEventHandler { [self] in
            var buffer = [UInt8](repeating: 0, count: 4096)
            guard let data = readAvailable(fd, into: &buffer) else {
                if currentMode() == .control {
                    send(["type": "terminal.release"])
                }
                source.cancel()
                onPeerGone()
                return
            }
            // Observe mode has no input path at all: bytes are read (so the
            // PTY never blocks) and discarded, never written to the herdr
            // child -- the structural read-only guarantee for an unfocused
            // pane moves from "no surface exists" to "the bridge drops
            // input," matched at herdr's own end by an observe client
            // having no input path either.
            guard currentMode() == .control else { return }
            send(ControlBridge.encodeInput(data))
        }
        source.resume()
        stdinSource = source
    }

    /// Commands the surface cannot express as keystrokes, plus the
    /// `paddock.mode` upgrade path. `paddock.mode` lines are intercepted
    /// here and never reach `send`/herdr at all; everything else is
    /// forwarded verbatim EXCEPT `terminal.scroll`, filtered by
    /// `ControlBridge.parseForwardableControlCommand` -- see its doc
    /// comment. Stays live in both modes: it is how a bridge born in
    /// observe mode ever learns to switch to control.
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
                if let requestedMode = ControlBridge.parseModeCommand(line) {
                    onModeCommand?(requestedMode)
                    continue
                }
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
            let size = PTYSize(cols: ws.cols, rows: ws.rows)
            // In observe mode this resize is view-local at herdr's end (18d);
            // in control mode it resizes the real pane -- either way the
            // bridge always sends it, so every pane's surface fits its cell
            // at its own font regardless of which verb is currently live.
            send(["type": "terminal.resize", "cols": size.cols, "rows": size.rows])
            onSizeChanged?(size)
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
