import FlockCore
import Foundation

/// One `/usr/bin/ssh` forward for a `MachineTunnel`.
///
/// `@unchecked Sendable`: `terminate()` can race the termination handler's
/// thread; `lock` guards the flag they share.
final class SSHTunnelProcess: MachineTunnelChild, @unchecked Sendable {
    static let sshPath = "/usr/bin/ssh"

    /// Buffered, so an exit before anyone iterates is still delivered.
    let exited: AsyncStream<String>

    private let process = Process()
    private let lock = NSLock()
    private var terminateRequested = false

    init(arguments: [String], environment: [String: String]) throws {
        let (exited, continuation) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .bufferingNewest(1))
        self.exited = exited
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: Self.sshPath)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe

        let stderr = StderrTailReader(handle: stderrPipe.fileHandleForReading)
        process.terminationHandler = { _ in
            stderr.finish { line in
                continuation.yield(line ?? "")
                continuation.finish()
            }
        }
        do {
            try process.run()
        } catch {
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
}
