import Darwin
import FlockCore
import Foundation

/// One `/usr/bin/ssh` forward for a `MachineTunnel`.
///
/// `@unchecked Sendable`: the termination and stderr handlers run on
/// Foundation's threads; `lock` guards everything they share.
final class SSHTunnelProcess: MachineTunnelChild, @unchecked Sendable {
    static let sshPath = "/usr/bin/ssh"
    /// Enough to hold ssh's last few lines; older output is dropped.
    private static let stderrTailLimit = 4096

    /// Buffered, so an exit before anyone iterates is still delivered.
    let exited: AsyncStream<String>

    private let continuation: AsyncStream<String>.Continuation
    private let process = Process()
    private let stderrPipe = Pipe()
    private let lock = NSLock()
    private var stderrTail = Data()
    private var terminateRequested = false

    init(arguments: [String], environment: [String: String]) throws {
        (exited, continuation) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .bufferingNewest(1))
        process.executableURL = URL(fileURLWithPath: Self.sshPath)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe

        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.appendStderr(data)
        }
        process.terminationHandler = { [weak self] _ in
            self?.finish()
        }
        do {
            try process.run()
        } catch {
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            continuation.finish()
            throw error
        }
    }

    func terminate() {
        lock.lock()
        let first = !terminateRequested
        terminateRequested = true
        lock.unlock()
        if first, process.isRunning { process.terminate() }
    }

    private func appendStderr(_ data: Data) {
        lock.withLock {
            stderrTail.append(data)
            if stderrTail.count > Self.stderrTailLimit {
                stderrTail.removeFirst(stderrTail.count - Self.stderrTailLimit)
            }
        }
    }

    /// The pipe is drained without blocking: a ProxyCommand child that
    /// inherited stderr can hold it open after ssh itself has exited.
    private func finish() {
        let reader = stderrPipe.fileHandleForReading
        reader.readabilityHandler = nil
        let fd = reader.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else { break }
            appendStderr(Data(buffer[0..<count]))
        }
        let tail = lock.withLock { stderrTail }
        continuation.yield(MachineSSH.lastLine(of: tail) ?? "")
        continuation.finish()
    }
}
