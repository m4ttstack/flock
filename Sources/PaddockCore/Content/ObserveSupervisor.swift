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
        if spawn(pane: pane, cols: cols, rows: rows, continuation: old.continuation) {
            touchAttachOrder(pane)
        } else {
            old.continuation.finish()
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
                    continuation.yield(frame)
                case .closed:
                    Task { [weak self, session] in await self?.handleSessionEnded(pane: pane, session: session) }
                case .ignored:
                    break
                }
            }
        }
        continuation.onTermination = { [weak self, session] _ in
            Task { [weak self, session] in await self?.handleSessionEnded(pane: pane, session: session) }
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

    /// Single funnel for every way a session can end: a `terminal.closed`
    /// line, the child exiting on its own, or the consumer dropping/
    /// cancelling the stream. The identity check discards late events from a
    /// session `reattach` has already replaced.
    private func handleSessionEnded(pane: PaneID, session: Session) {
        guard sessions[pane] === session, !session.isFinished else { return }
        session.markFinished()
        sessions.removeValue(forKey: pane)
        attachOrder.removeAll { $0 == pane }
        terminateWithEscalation(session.process)
        session.continuation.finish()
    }

    private func removeAndFinish(_ pane: PaneID) {
        guard let session = sessions.removeValue(forKey: pane) else { return }
        attachOrder.removeAll { $0 == pane }
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
    guard process.isRunning else { return }
    process.terminate()
    let pid = process.processIdentifier
    Task.detached {
        try? await Task.sleep(nanoseconds: 300_000_000)
        if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }
}
