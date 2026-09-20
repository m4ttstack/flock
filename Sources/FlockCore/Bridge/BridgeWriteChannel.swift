import Foundation
import os
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// One descriptor's outbound bytes: never parks the caller, never reorders,
/// never drops a byte it has accepted.
///
/// The bridge's frame write runs inside the herdr-output handler, on that
/// handle's own dispatch queue and under the lock every other stdout and
/// status write takes. A blocking `write()` there is a pane-wide deadlock:
/// a surface that stops draining its PTY parks the handler, so herdr's own
/// output stops being read as well and nothing on either side moves again
/// until something else drains the far end. So the descriptor is put in
/// `O_NONBLOCK` and a far end that is not taking bytes answers `EAGAIN`
/// instead. Whatever could not go is buffered here in arrival order and
/// written by a `DispatchSourceWrite` as the far end takes it, which is what
/// keeps a partial write resuming exactly where it stopped and a later write
/// behind an earlier one rather than interleaved mid escape sequence.
///
/// `SIGPIPE` must be ignored process-wide (`ControlBridge.run` does this
/// before any channel exists) or a reader that has gone away kills this
/// process instead of failing the write with `EPIPE`. `EINTR` is retried: a
/// signal delivered mid-write (SIGWINCH arrives constantly here) is not the
/// reader going away.
///
/// **`O_NONBLOCK` is set on the open file description, not on one
/// descriptor.** libghostty hands its PTY child `pty.slave` for all three
/// standard descriptors, so the flag this sets for stdout is the flag stdin
/// is read under: every read of the PTY has to treat `EAGAIN` as "nothing
/// right now" rather than as the surface going away (`readAvailable`).
///
/// `@unchecked Sendable`: `fd`, `limit`, `name`, `onOverflow` and `queue` are
/// immutable after init and `onOverflow` is only ever called on `queue`;
/// every other stored property is read and written under `lock`.
final class BridgeWriteChannel: @unchecked Sendable {
    /// What one `write` did with the bytes it was handed.
    enum Outcome: Equatable {
        /// Every byte left this process before the call returned.
        case delivered
        /// The far end was not taking bytes, so the rest is buffered and goes
        /// out, in order, as soon as it is.
        case queued
        /// Nothing went and nothing ever will: the reader is gone, the
        /// descriptor is not writable, or this channel is torn down.
        case failed
    }

    /// How much a far end may leave unread before it counts as gone. A pane's
    /// frames arrive only as fast as herdr sends them, so megabytes standing
    /// in a buffer is a reader that stopped, not a burst.
    static let defaultLimit = 4 << 20

    private let fd: Int32
    private let limit: Int
    private let name: String
    /// The channel hit its bound, reported on `queue` so the owner's teardown
    /// never runs inside the lock or on top of the caller's own stack.
    private let onOverflow: (() -> Void)?
    private let queue: DispatchQueue
    private let lock = NSLock()
    /// Bytes accepted and not yet written, with `start` marking how far into
    /// them the far end has taken. Held as `[UInt8]` rather than `Data` so the
    /// indices stay zero-based however the buffer is sliced.
    private var pending: [UInt8] = []
    private var start = 0
    private var writable: DispatchSourceWrite?
    private var armed = false
    private var broken = false
    /// Running totals, in bytes, of what this channel has accepted and what
    /// has actually left. A waiter is owed its callback once `written`
    /// reaches the total that stood when its write was accepted.
    private var accepted: UInt64 = 0
    private var written: UInt64 = 0
    private var waiters: [(target: UInt64, run: () -> Void)] = []

    init(
        fd: Int32, name: String, limit: Int = BridgeWriteChannel.defaultLimit,
        onOverflow: (() -> Void)? = nil
    ) {
        self.fd = fd
        self.name = name
        self.limit = limit
        self.onOverflow = onOverflow
        queue = DispatchQueue(label: "dev.mattstack.flock.bridge-write.\(name)", qos: .userInteractive)
        makeNonBlocking(fd)
    }

    deinit {
        // A suspended DispatchSource traps when it is released, so an idle
        // source is put back before it is let go.
        guard let writable else { return }
        if !armed { writable.resume() }
        writable.cancel()
    }

    /// Hands `data` to the descriptor, buffering whatever it will not take.
    ///
    /// `onDelivered` is for a caller that has to know the bytes really went,
    /// and fires only on the `.queued` path, on this channel's own queue, once
    /// the last of them has left; `.delivered` has already said the same thing
    /// synchronously, and a queued write that is abandoned (the bound, a dead
    /// reader, teardown) never fires at all. So it runs at most once per
    /// write, and only for bytes that reached the far end.
    @discardableResult
    func write(_ data: Data, onDelivered: (() -> Void)? = nil) -> Outcome {
        guard !data.isEmpty else { return .delivered }
        lock.lock()
        guard !broken else {
            lock.unlock()
            return .failed
        }

        var alreadyGone = 0
        if start == pending.count {
            // Nothing stands ahead of this, so it can go straight at the
            // descriptor: ordering only needs the buffer once the buffer has
            // something in it.
            let attempt = data.withUnsafeBytes { raw -> WriteAttempt in
                guard let base = raw.baseAddress else { return .failed }
                return attemptWrite(fd, base, raw.count)
            }
            switch attempt {
            case .wrote(let count):
                accepted += UInt64(count)
                written += UInt64(count)
                lock.unlock()
                return .delivered
            case .wouldBlock(let count):
                accepted += UInt64(count)
                written += UInt64(count)
                alreadyGone = count
            case .failed:
                tearDownLocked()
                lock.unlock()
                return .failed
            }
        }

        let remaining = data.count - alreadyGone
        guard (pending.count - start) + remaining <= limit else {
            tearDownLocked()
            lock.unlock()
            Self.log.error(
                "bridge write channel over its bound name=\(self.name, privacy: .public) limit=\(self.limit)")
            queue.async { [weak self] in self?.onOverflow?() }
            return .failed
        }
        pending.append(contentsOf: data.dropFirst(alreadyGone))
        accepted += UInt64(remaining)
        if let onDelivered { waiters.append((target: accepted, run: onDelivered)) }
        armLocked()
        lock.unlock()
        return .queued
    }

    /// Refuses everything from here on and drops whatever the far end never
    /// took. Called when the descriptor's owner is finished with it: a herdr
    /// child being replaced, or the bridge shutting down.
    func close() {
        lock.lock()
        tearDownLocked()
        let source = writable
        let wasArmed = armed
        writable = nil
        armed = false
        lock.unlock()
        guard let source else { return }
        if !wasArmed { source.resume() }
        source.cancel()
    }

    /// Bytes accepted and not yet written. A read-only seam for the tests.
    var queuedByteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pending.count - start
    }

    private func drain() {
        lock.lock()
        guard !broken, start < pending.count else {
            disarmLocked()
            lock.unlock()
            return
        }
        let attempt = pending.withUnsafeBufferPointer { buffer -> WriteAttempt in
            guard let base = buffer.baseAddress else { return .failed }
            return attemptWrite(fd, UnsafeRawPointer(base).advanced(by: start), pending.count - start)
        }
        switch attempt {
        case .wrote(let count):
            start += count
            written += UInt64(count)
            pending.removeAll(keepingCapacity: true)
            start = 0
            disarmLocked()
        case .wouldBlock(let count):
            start += count
            written += UInt64(count)
            compactLocked()
        case .failed:
            tearDownLocked()
        }
        let ready = takeReadyWaitersLocked()
        lock.unlock()
        for run in ready { run() }
    }

    /// Whatever the far end has already taken stops being carried, once it is
    /// worth a copy. Compacting on every partial write would copy the whole
    /// backlog per drain.
    private func compactLocked() {
        guard start >= 64 * 1024 else { return }
        pending.removeFirst(start)
        start = 0
    }

    private func takeReadyWaitersLocked() -> [() -> Void] {
        guard !waiters.isEmpty else { return [] }
        let ready = waiters.filter { $0.target <= written }
        waiters.removeAll { $0.target <= written }
        return ready.map(\.run)
    }

    private func tearDownLocked() {
        broken = true
        pending.removeAll()
        start = 0
        // Dropped rather than run: a waiter is a promise these bytes reached
        // the far end, and they did not.
        waiters.removeAll()
        disarmLocked()
    }

    private func armLocked() {
        if writable == nil {
            let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.drain() }
            writable = source
        }
        guard !armed else { return }
        armed = true
        writable?.resume()
    }

    private func disarmLocked() {
        guard armed else { return }
        armed = false
        writable?.suspend()
    }

    private static let log = Logger(subsystem: "dev.mattstack.flock", category: "bridge-write")
}

/// Puts `fd` in `O_NONBLOCK`, which is a property of the open file
/// description: on the PTY libghostty hands this process, that is the same
/// description stdin and stderr are read and written under.
func makeNonBlocking(_ fd: Int32) {
    guard fd >= 0 else { return }
    let flags = fcntl(fd, F_GETFL, 0)
    guard flags >= 0, flags & O_NONBLOCK == 0 else { return }
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
}

/// What one pass of `write()` on a non-blocking descriptor managed.
enum WriteAttempt {
    /// Every requested byte went.
    case wrote(Int)
    /// This many went; the far end would not take the rest right now.
    case wouldBlock(Int)
    /// The descriptor is finished: the reader is gone, or it was never
    /// writable in the first place.
    case failed
}

/// One best-effort pass at `count` bytes, retrying only what a signal
/// interrupted. Never blocks, as long as `fd` carries `O_NONBLOCK`.
func attemptWrite(_ fd: Int32, _ base: UnsafeRawPointer, _ count: Int) -> WriteAttempt {
    var sent = 0
    while sent < count {
        let n = write(fd, base.advanced(by: sent), count - sent)
        if n < 0 {
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { return .wouldBlock(sent) }
            return .failed
        }
        if n == 0 { return .failed }
        sent += n
    }
    return .wrote(sent)
}
