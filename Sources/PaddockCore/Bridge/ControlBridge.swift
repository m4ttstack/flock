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

    /// The size herdr's child is spawned at: the PTY's, the grid libghostty
    /// parses frames into. 80x24 covers only an axis the PTY reports as zero,
    /// which happens only with no tty behind the bridge.
    static func spawnSize(ptyWinsize: PTYSize) -> PTYSize {
        PTYSize(
            cols: ptyWinsize.cols > 0 ? ptyWinsize.cols : 80,
            rows: ptyWinsize.rows > 0 ? ptyWinsize.rows : 24
        )
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
        var processEnv = ProcessInfo.processInfo.environment
        if let socket = options.socketPath { processEnv["HERDR_SOCKET_PATH"] = socket }

        // Every child, the first and every retake, is spawned the same way and
        // at whatever the PTY reports right then: the size herdr is told still
        // comes only from this process's own tty.
        let supervisor = BridgeChildSupervisor(
            ptySize: { spawnSize(ptyWinsize: currentWinSize(fd: STDIN_FILENO)) },
            spawn: { size in
                let proc = Process()
                proc.executableURL = executableURL
                // Target before flags: herdr's CLI mis-parses a leading
                // `--takeover` as an unknown option.
                proc.arguments = prefixArguments
                    + childArgv(target: options.target, cols: size.cols, rows: size.rows)
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
                    return nil
                }
                return (proc, toHerdr.fileHandleForWriting.fileDescriptor, fromHerdr.fileHandleForReading)
            }
        )

        guard let first = supervisor.startFirstChild() else { exit(1) }

        // The app holds this FIFO's read end open (`PaneStatusChannel`), so
        // O_RDWR|O_NONBLOCK never blocks and never sees EOF; -1 (no pipe, or
        // it could not be opened) simply disables capture relaying, degrading
        // to the pre-passthrough selection-only behavior.
        let statusFD: Int32 = options.statusPipe.map { open($0, O_RDWR | O_NONBLOCK) } ?? -1
        if let statusPipe = options.statusPipe, statusFD < 0 {
            fputs("paddock-bridge: cannot open status pipe \(statusPipe)\n", stderr)
        }

        let io = BridgeIO(
            herdrInFD: first.input, statusFD: statusFD, spawnedSize: first.size,
            onHold: { supervisor.handle($0) },
            onSurfaceGone: { supervisor.shutdown() },
            onPeerGone: { supervisor.herdrOutputEnded() }
        )
        supervisor.attach(io: io)

        io.startStdin()
        io.startPTYSizeRelay()
        io.startHerdrOutput(first.output)
        if let controlPipe = options.controlPipe {
            io.startControlPipe(at: controlPipe)
        }

        let status = supervisor.wait()
        io.close()
        if statusFD >= 0 { Foundation.close(statusFD) }
        if var cookedTerminal { tcsetattr(STDIN_FILENO, TCSAFLUSH, &cookedTerminal) }
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
    /// reaches herdr only from the PTY itself (`BridgeIO.startPTYSizeRelay`).
    static func parseForwardableControlCommand(_ line: Data) -> [String: Any]? {
        guard
            let command = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            let type = command["type"] as? String,
            type.hasPrefix("terminal."),
            type != "terminal.resize"
        else { return nil }
        return command
    }

    /// The hold command on a control-FIFO line, or nil for anything else.
    /// Pure so the two commands the app can send can be tested apart from the
    /// child they drive.
    static func parseHoldCommand(_ line: Data) -> HoldCommand? {
        guard
            let command = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            let type = command["type"] as? String
        else { return nil }
        return HoldCommand(rawValue: type)
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
struct PTYResizeRelay: Sendable {
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

/// Whether the bridge's herdr child is paddock's to keep.
///
/// A child that exits while paddock holds the pane means herdr or the pane
/// itself is gone, and the bridge is finished with it. A child that exits
/// after a release IS the release: the bridge stays up, keeping the surface,
/// its PTY and its scrollback, and waits for the take that spawns the next
/// one. Pure, so both readings are testable without a real child.
struct BridgeHoldState: Equatable, Sendable {
    private(set) var isHolding = true

    /// Whether a release should actually be performed. A second release for
    /// an already released pane decides nothing.
    mutating func release() -> Bool {
        guard isHolding else { return false }
        isHolding = false
        return true
    }

    /// Whether a child should actually be spawned.
    mutating func take() -> Bool {
        guard !isHolding else { return false }
        isHolding = true
        return true
    }

    /// Whether a child exiting right now ends the bridge process.
    var childExitEndsTheBridge: Bool { isHolding }
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

/// The bridge's herdr child across releases and retakes.
///
/// One child at a time. `release` ends the current one WITHOUT ending the
/// bridge: this process, the surface it is the PTY child of, that surface's
/// scrollback and the pane's own program all stay, and herdr drops the pane's
/// `direct_attach_resize_lock` along with the client. `take` starts a
/// replacement at the PTY's current size, which retakes the lock and answers
/// with a full frame.
///
/// `@unchecked Sendable`: every mutable field is read and written only inside
/// `lock`. `io` is the one exception: written once by `attach(io:)` before
/// `wait()` and any FIFO command can reach `handle`, and only read after. The
/// cycle it reintroduces is inherent -- the IO routes hold commands here, and
/// a retake has to rewire that same IO onto the new child.
final class BridgeChildSupervisor: @unchecked Sendable {
    /// One spawned child: the fd herdr-bound lines are written to, the handle
    /// its NDJSON arrives on, and the size it was told at spawn.
    struct Child {
        let owner: BridgeChildOwner
        let process: Process
        let input: Int32
        let output: FileHandle
        let size: PTYSize
        let generation: Int
    }

    private let lock = NSLock()
    private let spawn: (PTYSize) -> (process: Process, input: Int32, output: FileHandle)?
    private let ptySize: () -> PTYSize
    private var io: BridgeIO?
    private var current: Child?
    private var hold = BridgeHoldState()
    private var finished = false
    private var generation = 0
    private var exitStatus: Int32 = 0
    /// Signalled once, when the bridge is finished.
    private let done = DispatchSemaphore(value: 0)
    /// Signalled when a take has a child for a parked waiter to watch.
    private let childReady = DispatchSemaphore(value: 0)

    init(
        ptySize: @escaping () -> PTYSize,
        spawn: @escaping (PTYSize) -> (process: Process, input: Int32, output: FileHandle)?
    ) {
        self.ptySize = ptySize
        self.spawn = spawn
    }

    /// The first child, spawned before any IO exists so `run` can wire the IO
    /// to its pipes. Returns nil when the spawn itself failed.
    func startFirstChild() -> Child? {
        let size = ptySize()
        guard let spawned = spawn(size) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        generation += 1
        let child = Child(
            owner: BridgeChildOwner(process: spawned.process), process: spawned.process,
            input: spawned.input, output: spawned.output, size: size, generation: generation
        )
        current = child
        return child
    }

    func attach(io: BridgeIO) {
        self.io = io
    }

    func handle(_ command: HoldCommand) {
        switch command {
        case .release: release()
        case .take: take()
        }
    }

    /// The herdr child's output ended. While paddock holds the pane that means
    /// herdr or the pane is gone; after a release it is the release itself.
    func herdrOutputEnded() {
        lock.lock()
        let holding = hold.isHolding
        lock.unlock()
        guard holding else { return }
        shutdown()
    }

    /// The PTY went away: the bridge is finished whether or not it holds.
    func shutdown() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let child = current
        lock.unlock()
        child?.owner.terminate()
        // A waiter parked between children would otherwise never look again.
        childReady.signal()
    }

    private func release() {
        lock.lock()
        guard hold.release(), let child = current else {
            lock.unlock()
            return
        }
        lock.unlock()
        // In this order: herdr is told to let the pane go while its stdin is
        // still open, the pipe then closes (which is the same detach a second
        // time, harmless), and the terminate is only the backstop for a child
        // that answers neither.
        io?.send(["type": "terminal.release"])
        io?.swapHerdrInput(to: -1)
        child.owner.terminate()
    }

    private func take() {
        lock.lock()
        guard hold.take() else {
            lock.unlock()
            return
        }
        lock.unlock()
        let size = ptySize()
        guard let spawned = spawn(size) else {
            // Nothing to hold the pane with. Stay released rather than claim a
            // lock that does not exist; the next take tries again.
            lock.lock()
            _ = hold.release()
            lock.unlock()
            return
        }
        lock.lock()
        generation += 1
        let child = Child(
            owner: BridgeChildOwner(process: spawned.process), process: spawned.process,
            input: spawned.input, output: spawned.output, size: size, generation: generation
        )
        current = child
        lock.unlock()
        // Input first, so the rearm's resize reaches the new child and not a
        // closed fd; then the output, whose generation bump makes the previous
        // handle inert.
        io?.swapHerdrInput(to: child.input)
        io?.startHerdrOutput(child.output)
        io?.rearmSpawnSize(size)
        childReady.signal()
    }

    /// Blocks until the bridge is finished, and returns the exit status of the
    /// child that finished it. Runs the watch loop on a thread of its own so
    /// the caller's own thread is free.
    func wait() -> Int32 {
        let watcher = Thread { [self] in watchChildren() }
        watcher.start()
        done.wait()
        lock.lock()
        defer { lock.unlock() }
        return exitStatus
    }

    private func watchChildren() {
        lock.lock()
        var watched = current
        lock.unlock()
        while let child = watched {
            child.process.waitUntilExit()
            lock.lock()
            if finished {
                lock.unlock()
                break
            }
            // A take that beat this wakeup already replaced the child: watch
            // the newer one instead of reading this exit as the bridge's.
            if current?.generation != child.generation {
                watched = current
                lock.unlock()
                continue
            }
            if hold.childExitEndsTheBridge {
                exitStatus = child.process.terminationStatus
                finished = true
                lock.unlock()
                break
            }
            lock.unlock()
            childReady.wait()
            lock.lock()
            watched = finished ? nil : current
            lock.unlock()
        }
        done.signal()
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
/// has returned. `winchSource` is written once, by `startPTYSizeRelay`,
/// under the same invariant. `resizeRelay` is read and written only inside
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
    /// The PTY went away, which is final: the surface this bridge exists for
    /// is gone. Distinct from `onPeerGone` (the herdr child's output ending),
    /// which is exactly what a release looks like and must not end the bridge.
    private let onSurfaceGone: () -> Void
    /// Called for a `paddock.*` hold command read off the control FIFO. A
    /// closure rather than a direct call into the supervisor so the FIFO's
    /// parse-and-route can be driven over a plain pipe in tests.
    private let onHold: (HoldCommand) -> Void
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
        onHold: @escaping (HoldCommand) -> Void = { _ in },
        onSurfaceGone: (() -> Void)? = nil,
        onPeerGone: @escaping () -> Void
    ) {
        self.onHold = onHold
        self.onSurfaceGone = onSurfaceGone ?? onPeerGone
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
    /// terminal, so a resize sent from SIGWINCH reaches herdr after the
    /// surface can take the full frame herdr answers it with. A size sent any
    /// earlier lands that frame in the old grid.
    ///
    /// The read after arming must follow it: a SIGWINCH delivered before the
    /// source exists is lost, and a new surface's PTY is resized a moment
    /// after the bridge forks.
    func startPTYSizeRelay() {
        signal(SIGWINCH, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .global(qos: .userInteractive))
        source.setEventHandler { [weak self] in
            self?.relayPTYSize()
        }
        source.resume()
        winchSource = source
        relayPTYSize()
    }

    /// Points the herdr-bound writes at a new child's stdin, closing the old
    /// one. `-1` parks the writes: `write()` to it fails immediately, which is
    /// what a released pane's stray `terminal.resize` needs to do.
    func swapHerdrInput(to fd: Int32) {
        writeLock.lock()
        defer { writeLock.unlock() }
        let previous = herdrInFD
        herdrInFD = fd
        if previous >= 0 { Foundation.close(previous) }
    }

    /// Reseeds the relay to the size a freshly spawned child was given, then
    /// sends whatever the PTY has become since that size was read. Without the
    /// reseed the relay would still be comparing against the size the PREVIOUS
    /// child was told, and a retake at an unchanged size would send herdr a
    /// resize it did not need.
    func rearmSpawnSize(_ size: PTYSize) {
        resizeLock.lock()
        resizeRelay = PTYResizeRelay(spawned: size)
        resizeLock.unlock()
        relayPTYSize()
    }

    /// Sends herdr the PTY's current size unless herdr already has it.
    private func relayPTYSize() {
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
                onSurfaceGone()
                return
            }
            send(ControlBridge.encodeInput(data))
        }
        source.resume()
        stdinSource = source
    }

    /// Commands the surface cannot express as keystrokes, forwarded verbatim
    /// (see `ControlBridge.parseForwardableControlCommand`).
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
                // Hold commands are read here and never forwarded: they are
                // `paddock.*`, which `parseForwardableControlCommand` already
                // refuses, so the order of these two is not what keeps them
                // off herdr's wire.
                if let hold = ControlBridge.parseHoldCommand(line) {
                    onHold(hold)
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
