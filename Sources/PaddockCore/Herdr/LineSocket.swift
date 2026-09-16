import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

public enum LineSocketError: Error, Sendable {
    case connectFailed(Int32)
    case closed
    case io(Int32)
}

/// Newline-framed duplex transport over a unix domain socket. Read state
/// (line buffering) lives on a private serial queue rather than as actor
/// storage: DispatchIO only ever invokes its callbacks on that queue, so
/// confining the buffer there keeps the hot read path off the actor without
/// racing it.
public actor LineSocket {
    private let fd: Int32
    private let queue: DispatchQueue
    private let channel: DispatchIO
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    public nonisolated let lines: AsyncThrowingStream<Data, Error>
    private var closed = false

    public init(path: String) async throws {
        let fd = try Self.openAndConnect(path: path)
        let queue = DispatchQueue(label: "dev.mattstack.paddock.linesocket")

        let (lines, cont) = AsyncThrowingStream<Data, Error>.makeStream()

        let channel = DispatchIO(type: .stream, fileDescriptor: fd, queue: queue) { _ in
            Foundation.close(fd)
        }
        channel.setLimit(lowWater: 1)

        let readBuffer = LineBuffer()
        channel.read(offset: 0, length: .max, queue: queue) { done, data, err in
            if let data, !data.isEmpty {
                readBuffer.append(data)
                while let line = readBuffer.popLine() {
                    cont.yield(line)
                }
            }
            if done {
                if err != 0 {
                    cont.finish(throwing: LineSocketError.io(err))
                } else {
                    cont.finish()
                }
            }
        }

        self.fd = fd
        self.queue = queue
        self.channel = channel
        self.lines = lines
        self.continuation = cont
    }

    /// Cancellable, which `DispatchIO.write` is not on its own: its handler
    /// fires when the write completes, and a write to a peer that has stopped
    /// reading does not complete once the socket buffer fills. A caller racing
    /// this against a deadline would then park on the send itself, which is
    /// the very thing such a deadline exists to prevent. Stopping the channel
    /// is what ends it: every outstanding write is completed with `ECANCELED`,
    /// which is a handler call with `done == true`, so the continuation
    /// resumes through the same path a real write error takes.
    public func send(line: Data) async throws {
        guard !closed else { throw LineSocketError.closed }
        var framed = line
        framed.append(0x0A)
        let channel = self.channel
        let queue = self.queue
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let dispatchData = framed.withUnsafeBytes { DispatchData(bytes: $0) }
                channel.write(offset: 0, data: dispatchData, queue: queue) { done, _, err in
                    // DispatchIO can invoke this handler more than once per write
                    // (partial progress reports); only the final call carries
                    // done == true, and only that call may resume the
                    // continuation, or a split write double-resumes it.
                    guard done else { return }
                    if err != 0 {
                        continuation.resume(throwing: LineSocketError.io(err))
                    } else {
                        continuation.resume()
                    }
                }
            }
        } onCancel: {
            // Not `close()`: that is actor-isolated, and this handler runs
            // wherever the cancel did. Stopping the channel here is the part
            // that unparks the write; the socket's own `close()` still runs on
            // the caller's path and is a no-op on an already-stopped channel.
            channel.close(flags: .stop)
        }
    }

    public func close() {
        guard !closed else { return }
        closed = true
        channel.close(flags: .stop)
        continuation.finish()
    }

    private static func openAndConnect(path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LineSocketError.connectFailed(errno) }

        var noSigPipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            Foundation.close(fd)
            throw LineSocketError.connectFailed(ENAMETOOLONG)
        }
        pathBytes.withUnsafeBytes { pathRaw in
            withUnsafeMutableBytes(of: &addr.sun_path) { raw in raw.copyBytes(from: pathRaw) }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
        }
        guard result == 0 else {
            let e = errno
            Foundation.close(fd)
            throw LineSocketError.connectFailed(e)
        }
        return fd
    }
}

/// Confined entirely to a LineSocket's private DispatchIO queue; never
/// touched from the actor's own isolation.
private final class LineBuffer: @unchecked Sendable {
    private var buffer = Data()

    func append(_ data: DispatchData) {
        buffer.append(contentsOf: data)
    }

    func popLine() -> Data? {
        guard let newline = buffer.firstIndex(of: 0x0A) else { return nil }
        let line = Data(buffer[buffer.startIndex..<newline])
        buffer.removeSubrange(buffer.startIndex...newline)
        return line
    }
}
