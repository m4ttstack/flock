import Foundation
import XCTest
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// XCTest has no async-throws assertion; this fills the gap used across the
/// transport tests.
func XCTAssertThrowsErrorAsync<T>(
    _ body: @autoclosure () async throws -> T,
    _ check: (Error) -> Void
) async {
    do {
        _ = try await body()
        XCTFail("expected throw")
    } catch {
        check(error)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

/// Emulates herdr's real api socket contract (validated against a live
/// server): one request per connection, then the server closes it.
/// `events.subscribe` is the one exception, an ack line followed by a stream
/// of pushed events on the same connection; any further inbound byte on that
/// connection is treated as a peer disconnect, exactly like the real server.
final class FakeHerdrServer: @unchecked Sendable {
    private enum Behavior {
        case success(String)
        case failure(code: String, message: String)
    }

    private let lock = NSLock()
    private var respondBehaviors: [String: String] = [:]
    // Consumed front-to-back, one entry per request for that method; once
    // drained, later requests fall through to `respondBehaviors` -- lets a
    // test give two sequential calls to the SAME method two different
    // responses (`respondBehaviors` alone can only ever hold one).
    private var respondQueues: [String: [String]] = [:]
    // One-shot: consumed by the next request for that method, then cleared,
    // falling through to `respondBehaviors` afterward.
    private var pendingFailures: [String: (code: String, message: String)] = [:]
    // One-shot per method, like pendingFailures: consumed by the next request
    // for that method, so a held connection can't wedge every later request.
    private var holds: [String: DispatchSemaphore] = [:]
    private var acceptsWithoutReading = false
    private var parkedFDs: Set<Int32> = []
    private var storedReceivedRequests: [(method: String, paramsJSON: String)] = []
    private var storedAcceptedConnectionCount = 0
    private var subscriberFDs: Set<Int32> = []
    private var running = false
    private var listenFD: Int32 = -1
    private let socketDir: String

    let socketPath: String

    private(set) var receivedRequests: [(method: String, paramsJSON: String)] {
        get { lock.withLock { storedReceivedRequests } }
        set { lock.withLock { storedReceivedRequests = newValue } }
    }

    private(set) var acceptedConnectionCount: Int {
        get { lock.withLock { storedAcceptedConnectionCount } }
        set { lock.withLock { storedAcceptedConnectionCount = newValue } }
    }

    init() {
        // A short, fixed-root path: NSTemporaryDirectory() can be long enough
        // on macOS to blow the 104-byte sun_path budget once a subdirectory
        // and filename are appended.
        var template = Array("/tmp/pdhsXXXXXX".utf8CString)
        let dir: String = template.withUnsafeMutableBufferPointer { buf in
            guard mkdtemp(buf.baseAddress) != nil else { return "/tmp" }
            return String(cString: buf.baseAddress!)
        }
        self.socketDir = dir
        self.socketPath = dir + "/h.sock"
    }

    func respond(to method: String, withResultJSON json: String) {
        lock.withLock { respondBehaviors[method] = json }
    }

    /// Queues a distinct response for each of the next `jsons.count`
    /// requests to `method`, consumed in order; a request beyond the queue
    /// falls back to whatever `respond(to:withResultJSON:)` was last given.
    func respondSequence(to method: String, withResultJSONs jsons: [String]) {
        lock.withLock { respondQueues[method] = jsons }
    }

    func failNext(method: String, code: String, message: String) {
        lock.withLock { pendingFailures[method] = (code: code, message: message) }
    }

    /// Blocks the connection thread for the next request matching `method`
    /// until the returned closure runs, so a test can pin an exact
    /// interleaving against an already-open subscription stream.
    ///
    /// The request is recorded in `receivedRequests` BEFORE the block, which
    /// is what lets a test wait for the method to arrive and still know
    /// nothing has been answered yet. Only that one request is held; a test
    /// that never releases leaves that connection's thread parked for the
    /// rest of the process, so release it on a `defer`.
    func holdNext(method: String) -> () -> Void {
        let sem = DispatchSemaphore(value: 0)
        lock.withLock { holds[method] = sem }
        return { sem.signal() }
    }

    /// Accept every later connection and then read nothing from it at all, so
    /// a client's write fills the socket buffer and stops making progress.
    /// That is the one failure a healthy-looking socket can still be in, and
    /// the only way to park a write on purpose: a server that reads is a
    /// server whose peer's writes always complete eventually.
    func acceptWithoutReading() {
        lock.withLock { acceptsWithoutReading = true }
    }

    func pushEventLine(_ json: String) {
        let fds = lock.withLock { subscriberFDs }
        for fd in fds where !writeLine(json, to: fd) {
            dropSubscriber(fd)
        }
    }

    func start() throws {
        try bindAndListen()
    }

    /// Rebinds to the same `socketPath` after `stop()`, simulating the
    /// daemon bouncing without the client's target address changing.
    func restart() throws {
        try FileManager.default.createDirectory(atPath: socketDir, withIntermediateDirectories: true)
        try bindAndListen()
    }

    private func bindAndListen() throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            Foundation.close(fd)
            throw POSIXError(.ENAMETOOLONG)
        }
        pathBytes.withUnsafeBytes { pathRaw in
            withUnsafeMutableBytes(of: &addr.sun_path) { raw in raw.copyBytes(from: pathRaw) }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Foundation.bind(fd, $0, size) }
        }
        guard bindResult == 0 else {
            let e = errno
            Foundation.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: e) ?? .EIO)
        }
        guard listen(fd, 128) == 0 else {
            let e = errno
            Foundation.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: e) ?? .EIO)
        }

        listenFD = fd
        running = true
        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.name = "FakeHerdrServer.accept"
        thread.start()
    }

    func stop() {
        let subs = lock.withLock { () -> Set<Int32> in
            running = false
            let s = subscriberFDs
            subscriberFDs.removeAll()
            return s
        }
        if listenFD >= 0 {
            Foundation.close(listenFD)
            listenFD = -1
        }
        for fd in subs { Foundation.close(fd) }
        for fd in lock.withLock({ () -> Set<Int32> in
            let parked = parkedFDs
            parkedFDs.removeAll()
            return parked
        }) { Foundation.close(fd) }
        try? FileManager.default.removeItem(atPath: socketDir)
    }

    private func acceptLoop() {
        while true {
            let clientFD = accept(listenFD, nil, nil)
            guard clientFD >= 0 else { return }
            let stillRunning = lock.withLock { () -> Bool in
                guard running else { return false }
                storedAcceptedConnectionCount += 1
                return true
            }
            guard stillRunning else {
                Foundation.close(clientFD)
                return
            }
            DispatchQueue.global().async { [weak self] in self?.handleConnection(clientFD) }
        }
    }

    private func handleConnection(_ fd: Int32) {
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        // Held open, never read and never closed: closing would fail the
        // client's write instead of parking it, which is the opposite of what
        // this mode is for. `stop()` closes them.
        let parked = lock.withLock { () -> Bool in
            guard acceptsWithoutReading else { return false }
            parkedFDs.insert(fd)
            return true
        }
        if parked { return }

        guard let request = readOneRequestLine(fd) else {
            Foundation.close(fd)
            return
        }
        lock.withLock { storedReceivedRequests.append((method: request.method, paramsJSON: request.paramsJSON)) }

        if let hold = lock.withLock({ holds.removeValue(forKey: request.method) }) {
            hold.wait()
        }

        if request.method == "events.subscribe" {
            // A pane-scoped subscription can be refused outright -- herdr
            // probes the pane when the subscription is created and errors if
            // it is gone -- and it answers with an error envelope on the same
            // connection, then ends it. Without this branch `failNext` was
            // silently ignored for subscribes and that path was untestable.
            if let failure = lock.withLock({ pendingFailures.removeValue(forKey: request.method) }) {
                let error = #"{"id":"\#(request.id)","error":{"code":"\#(failure.code)","message":"\#(failure.message)"}}"#
                writeLine(error, to: fd)
                Foundation.close(fd)
                return
            }
            let ack = #"{"id":"\#(request.id)","result":{"type":"subscription_started"}}"#
            guard writeLine(ack, to: fd) else {
                Foundation.close(fd)
                return
            }
            lock.withLock { subscriberFDs.insert(fd) }
            watchForDisconnect(fd)
            return
        }

        let behavior: Behavior? = lock.withLock {
            if let failure = pendingFailures.removeValue(forKey: request.method) {
                return .failure(code: failure.code, message: failure.message)
            }
            if var queue = respondQueues[request.method], !queue.isEmpty {
                let next = queue.removeFirst()
                respondQueues[request.method] = queue.isEmpty ? nil : queue
                return .success(next)
            }
            if let json = respondBehaviors[request.method] {
                return .success(json)
            }
            return nil
        }
        let responseLine: String
        switch behavior {
        case .success(let json)?:
            responseLine = #"{"id":"\#(request.id)","result":\#(json)}"#
        case .failure(let code, let message)?:
            responseLine = #"{"id":"\#(request.id)","error":{"code":"\#(code)","message":"\#(message)"}}"#
        case nil:
            responseLine = #"{"id":"\#(request.id)","error":{"code":"unhandled_method","message":"no behavior configured for \#(request.method)"}}"#
        }
        writeLine(responseLine, to: fd)
        Foundation.close(fd)
    }

    /// The real server tears a subscription connection down the instant it
    /// sees any inbound byte; this mirrors that so client code that
    /// accidentally writes on such a connection is caught by tests.
    private func watchForDisconnect(_ fd: Int32) {
        DispatchQueue.global().async { [weak self] in
            var byte: UInt8 = 0
            _ = read(fd, &byte, 1)
            self?.dropSubscriber(fd)
        }
    }

    private func dropSubscriber(_ fd: Int32) {
        let removed = lock.withLock { subscriberFDs.remove(fd) != nil }
        if removed { Foundation.close(fd) }
    }

    private func readOneRequestLine(_ fd: Int32) -> (method: String, paramsJSON: String, id: String)? {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = buf.withUnsafeMutableBytes { ptr in read(fd, ptr.baseAddress, ptr.count) }
            guard n > 0 else { return nil }
            data.append(contentsOf: buf[0..<n])
            guard let newline = data.firstIndex(of: 0x0A) else { continue }
            let line = Data(data[data.startIndex..<newline])
            guard
                let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                let id = obj["id"] as? String,
                let method = obj["method"] as? String
            else { return nil }
            let paramsObj = obj["params"] ?? [String: Any]()
            let paramsData = (try? JSONSerialization.data(withJSONObject: paramsObj)) ?? Data("{}".utf8)
            let paramsJSON = String(data: paramsData, encoding: .utf8) ?? "{}"
            return (method: method, paramsJSON: paramsJSON, id: id)
        }
    }

    @discardableResult
    private func writeLine(_ s: String, to fd: Int32) -> Bool {
        var data = Data(s.utf8)
        data.append(0x0A)
        return data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return raw.count == 0 }
            var offset = 0
            while offset < raw.count {
                let n = write(fd, base + offset, raw.count - offset)
                guard n > 0 else { return false }
                offset += n
            }
            return true
        }
    }
}
