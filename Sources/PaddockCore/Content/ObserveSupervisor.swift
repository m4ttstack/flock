import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

public enum ObserveSupervisorError: Error, Sendable {
    case herdrBinaryNotFound
}

/// Spawns and supervises `herdr terminal session observe <pane>` per attached
/// pane, decoding NDJSON frames off each child's stdout. AMENDED per spike 4:
/// `cols`/`rows` must equal the pane's real cell size (from the layout
/// snapshot rect) or the child silently top-crops the tail away from the
/// live cursor; this type does not resize or validate that, callers own it
/// and call `reattach` on every `layout.updated` for the pane.
///
/// A session ends only via explicit `detach`, `reattach` (kills the old
/// process), LRU eviction, actor `deinit`, a parsed `terminal.closed` line,
/// or the child process exiting. Dropping the `AsyncStream` returned by
/// `attach`/`reattach` without ever iterating it is deliberately NOT a
/// teardown trigger: `AsyncStream.Continuation.onTermination` cannot tell
/// "consumer cancelled mid-iteration" apart from "caller never even started
/// iterating," and treating the second case as a kill signal tears the
/// session down before the child has had a scheduler tick to run. Callers
/// that give up on a pane must call `detach` themselves.
public actor ObserveSupervisor {
    private let executablePath: String
    private let prefixArguments: [String]
    private let socketPath: String
    private let maxAttached: Int

    private var sessions: [PaneID: Session] = [:]
    // Oldest-attached first. Attach and reattach both count as a touch;
    // frame arrival does not, per the brief's own "least-recently-attached"
    // phrasing for the eviction test.
    private var attachOrder: [PaneID] = []
    // One cell per pane, surviving across reattaches: bumped on every spawn
    // so a stale in-flight read from the OLD process's pipe-queue thread can
    // tell, without touching actor state, that a newer spawn has already
    // taken over the (reused) continuation.
    private var generationCells: [PaneID: GenerationCell] = [:]

    public init(herdrBinary: String? = nil, socketPath: String, maxAttached: Int = 30) throws {
        if let herdrBinary, !herdrBinary.isEmpty {
            executablePath = herdrBinary
            prefixArguments = []
        } else if let fromEnv = ProcessInfo.processInfo.environment["HERDR_BIN"], !fromEnv.isEmpty {
            executablePath = fromEnv
            prefixArguments = []
        } else if Self.pathHasHerdr() {
            executablePath = "/usr/bin/env"
            prefixArguments = ["herdr"]
        } else {
            throw ObserveSupervisorError.herdrBinaryNotFound
        }
        self.socketPath = socketPath
        self.maxAttached = maxAttached
    }

    deinit {
        for session in sessions.values {
            terminateWithEscalation(session.process)
        }
    }

    public var attachedPanes: Set<PaneID> { Set(sessions.keys) }

    public func attach(_ pane: PaneID, cols: Int, rows: Int) -> AsyncStream<TerminalFrame> {
        removeAndFinish(pane)
        let (stream, continuation) = AsyncStream<TerminalFrame>.makeStream()
        if spawn(pane: pane, cols: cols, rows: rows, continuation: continuation) {
            touchAttachOrder(pane)
            evictOldestIfOverCapacity()
        }
        return stream
    }

    /// Kills the current child and respawns at the new dims while handing
    /// the SAME continuation to the new session, so a caller's `for await`
    /// loop survives a resize instead of needing to re-attach. This is a
    /// deliberate stream-identity choice: `reattach` returns Void because
    /// there is no new stream for the caller to pick up.
    public func reattach(_ pane: PaneID, cols: Int, rows: Int) {
        guard let old = sessions.removeValue(forKey: pane) else { return }
        attachOrder.removeAll { $0 == pane }
        old.markFinished()
        terminateWithEscalation(old.process)
        // spawn() finishes `old.continuation` itself if the respawn fails
        // (same Continuation object, reused for the new session below).
        if spawn(pane: pane, cols: cols, rows: rows, continuation: old.continuation) {
            touchAttachOrder(pane)
        }
    }

    public func detach(_ pane: PaneID) {
        removeAndFinish(pane)
    }

    // MARK: - spawning

    @discardableResult
    private func spawn(pane: PaneID, cols: Int, rows: Int, continuation: AsyncStream<TerminalFrame>.Continuation) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = prefixArguments + [
            "terminal", "session", "observe", pane.rawValue,
            "--cols", String(cols), "--rows", String(rows),
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["HERDR_SOCKET_PATH"] = socketPath
        process.environment = environment
        process.standardError = FileHandle.nullDevice

        let stdout = Pipe()
        process.standardOutput = stdout

        let session = Session(process: process, continuation: continuation)
        let buffer = ObserveLineBuffer()

        let cell = generationCells[pane] ?? GenerationCell()
        generationCells[pane] = cell
        let myGeneration = cell.bump()

        // `session` retains `process` retains `stdout`, and this closure
        // (installed on stdout's own fileHandle) retains `session`: a real
        // retain cycle. Broken only by `terminateWithEscalation` nil-ing
        // `readabilityHandler` on every teardown path below -- never rely on
        // ARC alone to tear this down.
        //
        // EOF is the sole "the child is done producing frames" trigger, not
        // Process.terminationHandler: this Pipe's write end is held only by
        // this one child, so EOF always follows its exit, and unlike
        // terminationHandler (a separate callback racing this serial read
        // queue) it cannot fire until every byte already read has been
        // parsed and yielded ahead of it.
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                Task { [weak self, session] in await self?.handleSessionEnded(pane: pane, session: session) }
                return
            }
            buffer.append(data)
            while let line = buffer.popLine() {
                switch ObserveWireLine.parse(line) {
                case .frame(let frame):
                    // Gated on the generation cell, not `session.isFinished`:
                    // a `reattach` can already have handed this same
                    // continuation to a NEW session by the time an in-flight
                    // read from THIS (old) process's queue finishes parsing,
                    // and that stale frame carries the OLD dims -- exactly
                    // the top-crop corruption the dims contract exists to
                    // prevent.
                    if cell.isCurrent(myGeneration) {
                        continuation.yield(frame)
                    }
                case .closed:
                    Task { [weak self, session] in await self?.handleSessionEnded(pane: pane, session: session) }
                case .ignored:
                    break
                }
            }
        }

        do {
            try process.run()
            sessions[pane] = session
            return true
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            session.markFinished()
            continuation.finish()
            return false
        }
    }

    /// Single funnel for the two ways a session ends on its own: a parsed
    /// `terminal.closed` line, or the child process exiting (observed as
    /// stdout EOF). The identity check discards late events from a session
    /// `reattach` has already replaced.
    private func handleSessionEnded(pane: PaneID, session: Session) {
        guard sessions[pane] === session, !session.isFinished else { return }
        session.markFinished()
        sessions.removeValue(forKey: pane)
        attachOrder.removeAll { $0 == pane }
        generationCells.removeValue(forKey: pane)
        terminateWithEscalation(session.process)
        session.continuation.finish()
    }

    private func removeAndFinish(_ pane: PaneID) {
        guard let session = sessions.removeValue(forKey: pane) else { return }
        attachOrder.removeAll { $0 == pane }
        generationCells.removeValue(forKey: pane)
        session.markFinished()
        terminateWithEscalation(session.process)
        session.continuation.finish()
    }

    private func touchAttachOrder(_ pane: PaneID) {
        attachOrder.removeAll { $0 == pane }
        attachOrder.append(pane)
    }

    private func evictOldestIfOverCapacity() {
        while sessions.count > maxAttached, let oldest = attachOrder.first {
            removeAndFinish(oldest)
        }
    }

    private static func pathHasHerdr() -> Bool {
        guard let path = ProcessInfo.processInfo.environment["PATH"] else { return false }
        return path.split(separator: ":").contains { segment in
            FileManager.default.isExecutableFile(atPath: "\(segment)/herdr")
        }
    }
}

/// Confined entirely to `ObserveSupervisor`'s actor isolation: the escaping
/// process/pipe callbacks only ever read `process` off it or pass it back
/// into an actor-isolated method, never touch `isFinished` themselves.
private final class Session: @unchecked Sendable {
    let process: Process
    let continuation: AsyncStream<TerminalFrame>.Continuation
    private(set) var isFinished = false

    init(process: Process, continuation: AsyncStream<TerminalFrame>.Continuation) {
        self.process = process
        self.continuation = continuation
    }

    func markFinished() { isFinished = true }
}

/// One per pane, surviving across reattaches. Unlike `Session.isFinished`
/// (confined to actor-isolated readers/writers), this is genuinely read from
/// an arbitrary pipe-reading queue and written from the actor, so it needs
/// the lock.
private final class GenerationCell: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func bump() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }

    func isCurrent(_ generation: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return value == generation
    }
}

/// Confined entirely to one process's stdout-reading queue.
private final class ObserveLineBuffer: @unchecked Sendable {
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

/// SIGTERM now, SIGKILL shortly after if the child is still alive. Runs
/// detached from the actor so it can be called from `deinit`, where actor
/// isolation is unavailable.
private func terminateWithEscalation(_ process: Process) {
    process.terminationHandler = nil
    if let pipe = process.standardOutput as? Pipe {
        pipe.fileHandleForReading.readabilityHandler = nil
    }
    // Always attempt this (terminate() on an already-exited process is a
    // documented no-op) rather than gating on `process.isRunning`: that
    // property is Foundation's own bookkeeping and isn't guaranteed to have
    // caught up with the kernel's view immediately after a rapid spawn. The
    // escalation check below asks the kernel directly instead.
    process.terminate()
    let pid = process.processIdentifier
    Task.detached {
        try? await Task.sleep(nanoseconds: 300_000_000)
        if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }
}
