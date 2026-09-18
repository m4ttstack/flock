// Portions derived from Herdglass (BSL-1.1), Sources/HerdrClient/ControlBridge.swift.
import Foundation
import os
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Everything the bridge needs, on its own argv: flock's ghostty surface
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
    /// which flock ever sees the pty: wiping it before the first real
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
    /// it only ever evicts a stale prior flock bridge on the SAME pane (the
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
            fputs("flock-bridge: --bridge <pane> is required\n", stderr)
            exit(2)
        }
        guard let executableURL = resolveHerdrBinary(explicit: options.herdrBinary) else {
            fputs("flock-bridge: cannot locate herdr (set --herdr-bin/HERDR_BIN or add it to PATH)\n", stderr)
            exit(2)
        }

        let cookedTerminal = enterRawMode()
        var processEnv = ProcessInfo.processInfo.environment
        if let socket = options.socketPath { processEnv["HERDR_SOCKET_PATH"] = socket }

        // One pipe for every child's stderr rather than one per child: this
        // process keeps the write end for its whole life, so the drain never
        // sees an EOF a retake would have to rearm it through.
        let herdrDiagnostics = Pipe()

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
                proc.arguments = childArgv(target: options.target, cols: size.cols, rows: size.rows)
                proc.environment = processEnv
                let toHerdr = Pipe()
                let fromHerdr = Pipe()
                proc.standardInput = toHerdr
                proc.standardOutput = fromHerdr
                // Never `FileHandle.standardError`: libghostty hands its PTY
                // child `pty.slave` for all three descriptors
                // (Vendor/ghostty/src/termio/Exec.zig), so a herdr that
                // inherited this process's stderr would write its diagnostics
                // straight onto the pane's mirrored screen.
                proc.standardError = herdrDiagnostics.fileHandleForWriting
                do {
                    try proc.run()
                } catch {
                    fputs("flock-bridge: failed to spawn herdr: \(error)\n", stderr)
                    return nil
                }
                return (proc, toHerdr.fileHandleForWriting, fromHerdr.fileHandleForReading)
            }
        )

        guard let first = supervisor.startFirstChild() else { exit(1) }

        // The app holds this FIFO's read end open (`PaneStatusChannel`), so
        // O_RDWR|O_NONBLOCK never blocks and never sees EOF; -1 (no pipe, or
        // it could not be opened) simply disables capture relaying, degrading
        // to the pre-passthrough selection-only behavior.
        let statusFD: Int32 = options.statusPipe.map { open($0, O_RDWR | O_NONBLOCK) } ?? -1
        if let statusPipe = options.statusPipe, statusFD < 0 {
            fputs("flock-bridge: cannot open status pipe \(statusPipe)\n", stderr)
        }

        let io = BridgeIO(
            herdrInFD: -1, statusFD: statusFD, spawnedSize: first.size,
            onHold: { supervisor.handle($0) },
            onSurfaceGone: { supervisor.shutdown() },
            onPeerGone: { generation in supervisor.herdrOutputEnded(generation: generation) }
        )
        supervisor.attach(io: io)
        // Through the swap, not the initializer, so the IO owns the handle it
        // will have to close when the first retake replaces it.
        io.swapHerdrInput(to: first.input)

        io.startStdin()
        io.startPTYSizeRelay()
        io.startHerdrDiagnostics(herdrDiagnostics.fileHandleForReading)
        supervisor.installOutput(for: first)
        if let controlPipe = options.controlPipe {
            io.startControlPipe(at: controlPipe)
        }

        supervisor.startWatching()
        let status = supervisor.waitUntilFinished()
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

    /// A `flock.mouse_capture` NDJSON line for a herdr `terminal.mouse_capture`
    /// line, or nil for anything else. This is how the bridge relays the one
    /// piece of pane state its `terminal.frame` stream drops (herdr's screen
    /// repaint never carries the mouse DECSET) out to the app on the status
    /// FIFO. Flock-namespaced so it can never be mistaken for a forwardable
    /// `terminal.*` command. A pure function so the parse is testable.
    static func encodeMouseCaptureStatus(_ line: Data) -> Data? {
        guard
            let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            object["type"] as? String == "terminal.mouse_capture",
            let enabled = object["enabled"] as? Bool
        else { return nil }
        let sgrPixels = object["sgr_pixels"] as? Bool ?? false
        return encodeLine([
            "type": "flock.mouse_capture",
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

    /// The app's "this pane's surface just took a new grid" nudge, acted on by
    /// the bridge itself (`BridgeIO.syncPTYSize`) rather than forwarded, which
    /// is why it is `flock.`-namespaced like the hold commands.
    ///
    /// It carries no size: the bridge sends herdr what the PTY actually has,
    /// never what the app believes. What makes the nudge necessary is that
    /// herdr resizes no pane flock holds -- every branch of
    /// `resize_tab_panes` (`herdr/src/ui/panes.rs`) skips a terminal in
    /// `direct_attach_resize_locks`, the zoom branch included -- so a box that
    /// grew reaches the pane's real grid through the PTY or not at all.
    static let sizeSyncCommandType = "flock.sync_size"

    static func isSizeSyncCommand(_ line: Data) -> Bool {
        guard let command = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return false }
        return command["type"] as? String == sizeSyncCommandType
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
///
/// Asking and recording are separate on purpose. A size counts as herdr's
/// only once it has actually been written to a live client: the descriptor is
/// parked at -1 for as long as flock's hold is released, and a relay that
/// recorded on the attempt would believe herdr had a size it never received,
/// with nothing to ever retry it -- every later trigger reads the same
/// winsize and finds nothing to do.
struct PTYResizeRelay: Sendable {
    private(set) var herdrSize: PTYSize?

    init(spawned: PTYSize?) {
        herdrSize = spawned
    }

    /// The size herdr is owed for the PTY's current `winsize`, or nil when it
    /// is unreadable or herdr already has it.
    func pending(_ winsize: PTYSize?) -> PTYSize? {
        guard let winsize, winsize.cols > 0, winsize.rows > 0, winsize != herdrSize else { return nil }
        return winsize
    }

    mutating func delivered(_ size: PTYSize) {
        herdrSize = size
    }
}

/// Whether the bridge's herdr child is flock's to keep.
///
/// A child that exits while flock holds the pane means herdr or the pane
/// itself is gone, and the bridge is finished with it. A child that exits
/// after a release IS the release: the bridge stays up, keeping the surface,
/// its PTY and its scrollback, and waits for the take that spawns the next
/// one. Pure, so both readings are testable without a real child.
struct BridgeHoldState: Equatable, Sendable {
    /// How a child's exit is read.
    enum ChildExit: Equatable, Sendable {
        /// Flock had let the pane go. The bridge stays up and waits.
        case expectedRelease
        /// The take never got a client. herdr refuses an attach by shutting the
        /// connection down (a pane with an alt-screen read in progress, or a
        /// session handoff rejecting every pending connection), which at this
        /// end looks exactly like a child exiting; only how soon after the take
        /// it happened tells them apart. A pane whose own program ended cannot
        /// land in this window, because flock only ever takes a pane whose
        /// frames it was already being sent.
        case refusedTake
        /// herdr or the pane is gone, and so is the bridge's reason to exist.
        case bridgeIsFinished
    }

    /// A retake's child that exits within this of its spawn is read as a
    /// refusal rather than as the pane's end.
    ///
    /// herdr refuses by dropping the connection, which takes milliseconds, so
    /// the width is all headroom against a loaded machine. Too narrow and a
    /// refusal that arrives late reads as the pane ending: the bridge
    /// finishes, and the surface is frozen with nothing left to rebuild it.
    /// Too wide costs only the opposite case, a pane whose own program exits
    /// just after a retake, which is retried the two times the backoff allows
    /// and then reported as a lost hold.
    static let refusedTakeWindow: TimeInterval = 2

    /// The waits before a refused take is tried again, in order. Running out
    /// is what ends the retries.
    static let takeRetryBackoff: [TimeInterval] = [0.25, 1]

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

    /// `fromTake` separates a retake's child from the bridge's first one: the
    /// first child is spawned for a pane flock has never seen, so its early
    /// exit really is "this pane cannot be attached" and must still end the
    /// bridge, exactly as it did before retakes existed.
    func reading(fromTake: Bool, childAge: TimeInterval) -> ChildExit {
        guard isHolding else { return .expectedRelease }
        guard fromTake, childAge < Self.refusedTakeWindow else { return .bridgeIsFinished }
        return .refusedTake
    }

    /// How long to wait before trying a refused take again, or nil when the
    /// bridge should stop trying and say so.
    static func retryDelay(afterFailedTakes failures: Int) -> TimeInterval? {
        guard failures >= 1, failures <= takeRetryBackoff.count else { return nil }
        return takeRetryBackoff[failures - 1]
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
    /// One spawned child: the handles its lines are written to and arrive on,
    /// the size it was told at spawn, and when it started.
    ///
    /// The handles are held, not their descriptor numbers: a `Pipe`'s handle
    /// owns its descriptor and closes it on dealloc, so a number taken out of
    /// one and closed by hand is a number the next `pipe()` can reclaim and the
    /// original handle can then close out from under it.
    struct Child {
        let owner: BridgeChildOwner
        let process: Process
        let input: FileHandle
        let output: FileHandle
        let size: PTYSize
        let generation: Int
        /// Whether a take spawned this one, as opposed to the bridge's own
        /// start. It is what lets an early exit be read as herdr refusing the
        /// retake rather than as the pane failing to attach at all.
        let fromTake: Bool
        /// The hold epoch this child was spawned under, so a retry after it is
        /// refused is checked against the attempt that failed rather than
        /// against whatever the epoch has become by the time the retry is
        /// armed. Re-deriving it later would adopt an intervening release's own
        /// epoch as the retry's baseline, and the retry would then pass its
        /// check and retake the pane behind an app that had let go.
        let epoch: Int
        let startedAt: Date
    }

    typealias Spawned = (process: Process, input: FileHandle, output: FileHandle)

    /// Guards every mutable field AND carries the watcher's wait. A condition
    /// rather than a lock plus a counting semaphore: the state is the truth
    /// about which child to watch, so a wakeup posted for a child the watcher
    /// has already picked up must not be able to satisfy a later wait.
    private let lock = NSCondition()
    private let spawn: (PTYSize) -> Spawned?
    private let ptySize: () -> PTYSize
    private let now: () -> Date
    private let scheduleRetry: (TimeInterval, @escaping () -> Void) -> Void
    /// Runs between a refusal being classified and the retry being armed.
    /// Empty in production, and injected only by this class's own tests: that
    /// window is a few instructions wide, so a release landing inside it cannot
    /// be driven any other way, and it is the window in which the retry's
    /// baseline epoch would go wrong.
    private let afterRefusalObserved: () -> Void
    private var io: BridgeIO?
    private var current: Child?
    private var hold = BridgeHoldState()
    private var finished = false
    private var generation = 0
    /// The output generation whose EOF is meaningful. Zero while no output is
    /// installed, which is the window a take opens between claiming the hold
    /// and wiring the new child: an EOF arriving from the PREVIOUS child in
    /// that window would otherwise read as this one dying.
    private var expectedOutputGeneration = 0
    private var failedTakes = 0
    /// Bumped by the app's own release and by a shutdown. A retry carries the
    /// epoch it was armed under and does nothing if it no longer matches, which
    /// is what stops a refused pane from taking herdr's lock back behind an app
    /// that has already let go: while a retry is armed the bridge is in the
    /// RELEASED state, so a release arriving then has no hold to drop and would
    /// otherwise cancel nothing at all.
    private var holdEpoch = 0
    /// Set only by the watcher, which is the one place that reads a child's
    /// exit as the bridge's. A shutdown from the PTY side leaves it nil and the
    /// status is taken from the child itself, which is what `run` did directly
    /// before the bridge could outlive a child at all.
    private var exitStatus: Int32?
    /// Signalled once, when the bridge is finished.
    private let done = DispatchSemaphore(value: 0)

    init(
        ptySize: @escaping () -> PTYSize,
        now: @escaping () -> Date = Date.init,
        scheduleRetry: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay, execute: work)
        },
        afterRefusalObserved: @escaping () -> Void = {},
        spawn: @escaping (PTYSize) -> Spawned?
    ) {
        self.ptySize = ptySize
        self.now = now
        self.scheduleRetry = scheduleRetry
        self.afterRefusalObserved = afterRefusalObserved
        self.spawn = spawn
    }

    /// The first child, spawned before any IO exists so `run` can wire the IO
    /// to its pipes. Returns nil when the spawn itself failed.
    func startFirstChild() -> Child? {
        spawnChild(fromTake: false, epoch: 0)
    }

    func attach(io: BridgeIO) {
        self.io = io
    }

    /// Arms the IO on a child's output and records the generation, so an EOF
    /// can be matched against the handle it came from. Returns that generation.
    @discardableResult
    func installOutput(for child: Child) -> Int {
        let generation = io?.startHerdrOutput(child.output) ?? 0
        lock.lock()
        expectedOutputGeneration = generation
        lock.unlock()
        return generation
    }

    func handle(_ command: HoldCommand) {
        switch command {
        case .release: release()
        case .take: take(isRetry: false)
        }
    }

    /// The herdr child's output ended. This path only ever escalates the
    /// unambiguous reading: an EOF from a superseded handle decides nothing,
    /// and neither does one inside the refusal window, because the watcher owns
    /// that case and the exit that makes it a refusal is what wakes it. Reading
    /// a refusal here instead would end the bridge before the retry could run.
    func herdrOutputEnded(generation: Int) {
        lock.lock()
        let stale = generation != expectedOutputGeneration
        let child = current
        let reading = child.map { child in
            hold.reading(
                fromTake: child.fromTake, childAge: now().timeIntervalSince(child.startedAt)
            )
        }
        lock.unlock()
        guard !stale else { return }
        if reading == .refusedTake {
            // The watcher classifies a refusal, and only the child's EXIT wakes
            // it. A child whose output has already ended has nothing left to
            // say, so ending it here is what makes that wakeup certain rather
            // than assumed: without it, a child that closed stdout and did not
            // exit would park the watcher forever with the hold still claimed.
            child?.owner.terminate()
            return
        }
        guard reading == .bridgeIsFinished else { return }
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
        // Past this point no retry may spawn anything, and a waiter parked
        // between children has to look again or it never would.
        holdEpoch += 1
        let child = current
        lock.broadcast()
        lock.unlock()
        child?.owner.terminate()
    }

    private func release() {
        lock.lock()
        // Bumped whether or not this changes the hold. A release that arrives
        // while a retry is armed has no hold to drop, but it must still stop
        // that retry: otherwise a refused pane takes herdr's lock back minutes
        // later, behind an app that has already let go.
        holdEpoch += 1
        failedTakes = 0
        let wasHolding = hold.release()
        let child = wasHolding ? current : nil
        expectedOutputGeneration = 0
        lock.broadcast()
        lock.unlock()
        guard let child else { return }
        // In this order: herdr is told to let the pane go while its stdin is
        // still open, the pipe then closes (which is the same detach a second
        // time, harmless), and the terminate is only the backstop for a child
        // that answers neither.
        io?.send(["type": "terminal.release"])
        io?.swapHerdrInput(to: nil)
        child.owner.terminate()
    }

    /// `epoch` is the hold epoch a RETRY was armed under; an app-driven take
    /// passes nil and is always current by definition.
    private func take(isRetry: Bool, epoch: Int? = nil) {
        lock.lock()
        if finished || (epoch.map { $0 != holdEpoch } ?? false) {
            lock.unlock()
            return
        }
        guard hold.take() else {
            lock.unlock()
            return
        }
        // A take the app asked for starts the retry budget over: the user has
        // switched back, whatever refused the last one is likely gone.
        if !isRetry { failedTakes = 0 }
        // Nothing is installed until the new child's output is, so an EOF from
        // the previous one cannot be read as this child dying.
        expectedOutputGeneration = 0
        let spawnEpoch = holdEpoch
        lock.unlock()
        guard let child = spawnChild(fromTake: true, epoch: spawnEpoch) else {
            lock.lock()
            // A release or shutdown that landed while this was spawning already
            // owns the state, and `spawnChild` has already ended the child it
            // was in the middle of starting. Only a real spawn failure rolls
            // back and retries.
            let superseded = spawnEpoch != holdEpoch || finished
            if !superseded { _ = hold.release() }
            lock.unlock()
            if !superseded { retryOrGiveUp(epoch: spawnEpoch) }
            return
        }
        // Input first, so the rearm's resize reaches the new child and not a
        // closed handle; then the output, whose generation bump makes the
        // previous handle inert.
        io?.swapHerdrInput(to: child.input)
        installOutput(for: child)
        io?.rearmSpawnSize(child.size)
    }

    /// Spawning happens outside the lock, so the epoch is checked again once it
    /// is held: a child started for a hold the app has since let go is a herdr
    /// client the bridge does not know it has, and goes with the release that
    /// overtook it rather than being installed.
    private func spawnChild(fromTake: Bool, epoch: Int) -> Child? {
        let size = ptySize()
        guard let spawned = spawn(size) else { return nil }
        let owner = BridgeChildOwner(process: spawned.process)
        lock.lock()
        guard epoch == holdEpoch, !finished else {
            lock.unlock()
            owner.terminate()
            return nil
        }
        generation += 1
        let child = Child(
            owner: owner, process: spawned.process,
            input: spawned.input, output: spawned.output, size: size, generation: generation,
            fromTake: fromTake, epoch: epoch, startedAt: now()
        )
        current = child
        lock.broadcast()
        lock.unlock()
        return child
    }

    /// A refused take: schedule the next attempt, or stop and tell the app the
    /// pane has no hold, so it can mark it rather than keep showing a frame
    /// that is quietly no longer live.
    ///
    /// `epoch` is the one the FAILED attempt was made under, carried in rather
    /// than read here. A release landing between that failure and this call has
    /// already decided the pane is not ours: it must cancel the retry, and it
    /// must not raise a hold-lost card for a pane the app let go on purpose.
    private func retryOrGiveUp(epoch: Int) {
        lock.lock()
        guard epoch == holdEpoch, !finished else {
            lock.unlock()
            return
        }
        failedTakes += 1
        let delay = BridgeHoldState.retryDelay(afterFailedTakes: failedTakes)
        lock.unlock()
        guard let delay else {
            // The next full frame has to be able to clear the card this puts up.
            io?.rearmFirstFrame()
            io?.sendStatus(["type": HoldStatus.lost.rawValue])
            return
        }
        scheduleRetry(delay) { [weak self] in
            self?.take(isRetry: true, epoch: epoch)
        }
    }

    /// Starts the watch loop on a thread of its own so the caller's is free.
    func startWatching() {
        Thread { [self] in watchChildren() }.start()
    }

    /// Blocks until the bridge is finished, and returns the exit status of the
    /// child that finished it.
    func waitUntilFinished() -> Int32 {
        done.wait()
        lock.lock()
        let recorded = exitStatus
        let child = current
        lock.unlock()
        if let recorded { return recorded }
        guard let child, !child.process.isRunning else { return 0 }
        return child.process.terminationStatus
    }

    /// Whether the BRIDGE is done, which a release and a retake both leave
    /// false however many children come and go. A read-only seam for the
    /// tests: `waitUntilFinished()` is the production reader and it blocks, so
    /// the assertion every release/retake case actually needs -- that the
    /// bridge is still up -- has no other form.
    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    private func watchChildren() {
        lock.lock()
        var watched = current
        lock.unlock()
        while let child = watched {
            child.process.waitUntilExit()
            let exitedAt = now()
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
            let reading = hold.reading(
                fromTake: child.fromTake, childAge: exitedAt.timeIntervalSince(child.startedAt)
            )
            if reading == .bridgeIsFinished {
                exitStatus = child.process.terminationStatus
                finished = true
                lock.broadcast()
                lock.unlock()
                break
            }
            if reading == .refusedTake {
                _ = hold.release()
                expectedOutputGeneration = 0
                lock.unlock()
                io?.swapHerdrInput(to: nil)
                afterRefusalObserved()
                retryOrGiveUp(epoch: child.epoch)
            } else {
                lock.unlock()
            }
            watched = awaitNextChild(after: child.generation)
        }
        done.signal()
    }

    /// Parks until there is a child this loop has not watched, or the bridge
    /// finishes. The predicate, not a wakeup count, is what decides: a
    /// broadcast posted for a child already picked up simply re-tests it.
    private func awaitNextChild(after generation: Int) -> Child? {
        lock.lock()
        defer { lock.unlock() }
        while !finished {
            if let child = current, child.generation != generation { return child }
            lock.wait()
        }
        return nil
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
/// into `BridgeOptions`) wins, and flock itself always passes one it resolved
/// against the user's real PATH (`GhosttyControlSurfaceFactory`). The `PATH`
/// fallback is for a bridge run by hand, and inherits whatever PATH that hand
/// had: a bridge started by an app under launchd has no profile on its PATH
/// and would find nothing here.
private func resolveHerdrBinary(explicit: String?) -> URL? {
    if let explicit, !explicit.isEmpty {
        return URL(fileURLWithPath: explicit)
    }
    let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
    return UserPath.resolve("herdr", on: path).map { URL(fileURLWithPath: $0) }
}

/// Writes every byte, tolerating a reader that has already gone away.
/// Requires `SIGPIPE` to be ignored process-wide (`ControlBridge.run` does
/// this before any of these are reachable).
/// Returns whether every byte actually went. A caller that only needs the
/// side effect can ignore it; the size relay cannot, since a size counts as
/// herdr's only once it has really been written (see `PTYResizeRelay`).
@discardableResult
func writeIgnoringBrokenPipe(_ fd: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return false }
        var sent = 0
        while sent < raw.count {
            let n = write(fd, base.advanced(by: sent), raw.count - sent)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return false }
            sent += n
        }
        return true
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
    /// Set only when this IO owns the handle behind `herdrInFD` and so must
    /// close it on the next swap. Nil for the bare-descriptor form the tests
    /// use, which owns nothing.
    private var herdrInHandle: FileHandle?
    private let stdinFD: Int32
    private let stdoutFD: Int32
    /// The bridge -> app status FIFO (`--status-pipe`), write-only from here,
    /// or -1 when no status pipe was configured. Written under `stdoutLock`
    /// alongside the frame writes.
    private let statusFD: Int32
    /// The herdr child's output ended, carrying the generation the handler was
    /// installed under so a stale handle's EOF can be told from the current
    /// child's. The IO's own generation check only suppresses a SUPERSEDED
    /// handler; the supervisor needs the number to decide the case where no
    /// handler has been installed yet.
    private let onPeerGone: (Int) -> Void
    /// The PTY went away, which is final: the surface this bridge exists for
    /// is gone. Distinct from `onPeerGone` (the herdr child's output ending),
    /// which is exactly what a release looks like and must not end the bridge.
    private let onSurfaceGone: () -> Void
    /// Called for a `flock.*` hold command read off the control FIFO. A
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
    /// Latches on the first frame of any kind written to the PTY, which is the
    /// moment the pane becomes a mirror of herdr's screen and stops being a
    /// place anything else may write. Separate from `firstFrameSent`, which
    /// answers a different question (has the APP been told) and is gated on a
    /// full frame and on a status pipe existing at all. Guarded by
    /// `stdoutLock`.
    private var paintedAnyFrame = false
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
        onPeerGone: @escaping (Int) -> Void
    ) {
        self.onHold = onHold
        self.onSurfaceGone = onSurfaceGone ?? { onPeerGone(0) }
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

    /// Points the herdr-bound writes at a new child's stdin, closing the
    /// previous child's. `nil` parks the writes: the descriptor becomes -1 and
    /// `write()` to it fails immediately, which is what a released pane's stray
    /// `terminal.resize` needs to do.
    ///
    /// Closed through the handle, never by descriptor number: the number
    /// belongs to a live `Pipe` whose own `FileHandle` (`closeOnDealloc`) would
    /// close it a second time when the previous child is finally released, and
    /// the next child's `pipe()` has already reclaimed that number by then.
    /// `closeFile()` marks the handle closed, so the deinit does not repeat it.
    func swapHerdrInput(to handle: FileHandle?) {
        writeLock.lock()
        defer { writeLock.unlock() }
        herdrInHandle?.closeFile()
        herdrInHandle = handle
        herdrInFD = handle?.fileDescriptor ?? -1
    }

    /// The descriptor herdr-bound lines are written to. A read-only seam for
    /// the tests, and the one thing a `send` cannot stand in for: what a
    /// retake can get wrong is the descriptor's identity -- closed under it,
    /// or the freed number reclaimed by the next child's `pipe()` -- and a
    /// write reports neither, since it fails the same silent way either way.
    var herdrInputDescriptor: Int32 {
        writeLock.lock()
        defer { writeLock.unlock() }
        return herdrInFD
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

    /// When the app's nudge re-reads the PTY, after the read the nudge itself
    /// makes. libghostty hands its IO thread the new grid and returns, so the
    /// PTY's own `TIOCSWINSZ` lands a moment after the app can see the surface
    /// take that grid; a single read at the nudge can still be the old size.
    /// Every re-read that finds nothing new is silent (`PTYResizeRelay`), so
    /// the cost of the window is the reads themselves.
    static let sizeSyncReReadsMilliseconds = [30, 120, 400]

    /// The app saw this pane's surface take a new grid. SIGWINCH is the
    /// primary trigger and this changes nothing about it: a winsize herdr
    /// already has stays unsent however it is noticed.
    func syncPTYSize() {
        relayPTYSize(trigger: "sync")
        for milliseconds in Self.sizeSyncReReadsMilliseconds {
            DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + .milliseconds(milliseconds)) { [weak self] in
                self?.relayPTYSize(trigger: "sync.reread")
            }
        }
    }

    /// Sends herdr the PTY's current size unless herdr already has it, and
    /// records it as herdr's only if the write actually went.
    ///
    /// Logged, both ways. Twice now a resize that never reached herdr has been
    /// read off a screenshot as a pane that would not resize, when what had
    /// really happened was that flock's hold was released and the pane had no
    /// herdr client at all. The descriptor is the only place that difference
    /// exists, and it is here.
    private func relayPTYSize(trigger: String = "signal") {
        resizeLock.lock()
        defer { resizeLock.unlock() }
        guard let size = resizeRelay.pending(ptySize()) else { return }
        guard send(["type": "terminal.resize", "cols": size.cols, "rows": size.rows]) else {
            Self.sizeLog.error(
                "pty resize not delivered trigger=\(trigger, privacy: .public) cols=\(size.cols) rows=\(size.rows) herdrFD=\(self.herdrInputDescriptor)"
            )
            return
        }
        resizeRelay.delivered(size)
        Self.sizeLog.log(
            "pty resize sent trigger=\(trigger, privacy: .public) cols=\(size.cols) rows=\(size.rows)"
        )
    }

    private static let sizeLog = Logger(subsystem: "dev.mattstack.flock", category: "size")

    @discardableResult
    func send(_ object: [String: Any]) -> Bool {
        guard let payload = ControlBridge.encodeLine(object) else { return false }
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !closed else { return false }
        return writeIgnoringBrokenPipe(herdrInFD, payload)
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
            fputs("flock-bridge: cannot open control pipe \(path)\n", stderr)
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
                // `flock.*`, which `parseForwardableControlCommand` already
                // refuses, so the order of these two is not what keeps them
                // off herdr's wire.
                if let hold = ControlBridge.parseHoldCommand(line) {
                    onHold(hold)
                    continue
                }
                if ControlBridge.isSizeSyncCommand(line) {
                    syncPTYSize()
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
    ///
    /// Returns the generation it installed under, which the supervisor keeps so
    /// an EOF can be matched against the handle it came from.
    @discardableResult
    func startHerdrOutput(_ herdrOut: FileHandle) -> Int {
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
                if stillCurrent { onPeerGone(generation) }
                return
            }
            lines.append(data)
            while let line = lines.popLine() {
                if let frame = ControlBridge.parseFrame(line) {
                    stdoutLock.lock()
                    let stillCurrent = herdrOutputGeneration == generation
                    if stillCurrent {
                        writeIgnoringBrokenPipe(stdoutFD, frame.bytes)
                        paintedAnyFrame = true
                    }
                    var firstFrameLine: Data?
                    if stillCurrent, frame.full, !firstFrameSent, statusFD >= 0 {
                        firstFrameSent = true
                        firstFrameLine = ControlBridge.encodeLine(["type": "flock.first_frame"])
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
        return generation
    }

    func startHerdrDiagnostics(_ herdrErr: FileHandle) {
        let lines = BridgeLineBuffer()
        herdrErr.readabilityHandler = { [self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            lines.append(data)
            while let line = lines.popLine() {
                relayHerdrDiagnostic(line)
            }
        }
    }

    private func relayHerdrDiagnostic(_ line: Data) {
        // The PTY is in raw mode (`enterRawMode`), so ONLCR is off and a bare
        // newline would leave the next line indented by the whole width.
        var bytes = line
        bytes.append(contentsOf: [0x0D, 0x0A])
        stdoutLock.lock()
        let mirrored = paintedAnyFrame
        if !mirrored { writeIgnoringBrokenPipe(stdoutFD, bytes) }
        stdoutLock.unlock()
        guard mirrored else { return }
        Self.herdrLog.error("\(String(decoding: line, as: UTF8.self), privacy: .public)")
    }

    private static let herdrLog = Logger(subsystem: "dev.mattstack.flock", category: "herdr")

    /// One app-bound line on the status FIFO for something the frame stream
    /// cannot carry. Under `stdoutLock`, like the other two status writes.
    func sendStatus(_ object: [String: Any]) {
        guard statusFD >= 0, let payload = ControlBridge.encodeLine(object) else { return }
        stdoutLock.lock()
        defer { stdoutLock.unlock() }
        writeIgnoringBrokenPipe(statusFD, payload)
    }

    /// Un-latches the first-frame gate so the next full frame announces itself
    /// again. Only the give-up path calls this: the app puts a pane's status
    /// card back when its hold is lost for good, and that card has to be able
    /// to go away again when a later take succeeds.
    func rearmFirstFrame() {
        stdoutLock.lock()
        defer { stdoutLock.unlock() }
        firstFrameSent = false
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
