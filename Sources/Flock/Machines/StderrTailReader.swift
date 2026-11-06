import Darwin
import FlockCore
import Foundation

/// Keeps the tail of a pipe's output and hands back its last non-empty line.
///
/// Every read runs on one serial queue, so `finish` drains only after any
/// read already in flight. Reads use read(2) on a non-blocking descriptor:
/// a ProxyCommand child that inherited the pipe can hold it open after ssh
/// has exited, so the final drain must not wait for EOF.
///
/// `@unchecked Sendable`: `tail` and `finished` are touched only on `queue`.
final class StderrTailReader: @unchecked Sendable {
    private let handle: FileHandle
    private let queue = DispatchQueue(label: "dev.mattstack.flock.ssh-stderr")
    private let source: DispatchSourceRead
    private let limit: Int
    private var tail = Data()
    private var finished = false

    init(handle: FileHandle, limit: Int = 4096) {
        self.handle = handle
        self.limit = limit
        let fd = handle.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.drain() }
        // The descriptor must stay open until dispatch has let go of it.
        source.setCancelHandler { _ = handle }
        source.resume()
    }

    deinit {
        source.cancel()
    }

    /// Drains what the pipe holds now, then calls `completion` on the
    /// reader's queue with the last non-empty line. Later output is ignored.
    func finish(_ completion: @escaping @Sendable (String?) -> Void) {
        queue.async { [self] in
            drain()
            finished = true
            source.cancel()
            completion(MachineSSH.lastLine(of: tail))
        }
    }

    private func drain() {
        guard !finished else { return }
        let fd = handle.fileDescriptor
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                tail.append(contentsOf: buffer[0..<count])
                if tail.count > limit { tail.removeFirst(tail.count - limit) }
                continue
            }
            if count < 0, errno == EINTR { continue }
            // A readable source fires forever at EOF.
            if count == 0 { source.cancel() }
            return
        }
    }
}
