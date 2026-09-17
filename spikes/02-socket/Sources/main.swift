// Throwaway probe. Core shape mirrors what Task 11 will build for real.
// Validates DispatchIO unix-socket NDJSON framing against a real herdr scratch session.
//
// Deviation from the brief's literal read of "1000 rapid pane.get requests on
// ONE connection": exploratory testing against the real server (see
// FINDINGS.md) showed herdr's api socket answers exactly one request per
// connection, then closes it; only events.subscribe holds a connection open,
// and only for streaming (it does not accept further requests once acked).
// This probe runs the AS-SPECIFIED single-connection scenario first (to
// produce the precise failure evidence the brief asks for), then verifies the
// pattern Task 11 must actually use: one connection per request.
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

// MARK: - LineSocket
//
// The skeleton drives DispatchIO on `.main` and blocks nothing; a synchronous
// probe needs its main thread to block on semaphores while requests are in
// flight, so `.main` would deadlock (the read callback could never run).
// Each LineSocket gets its own private serial queue instead.
//
// Also not in the skeleton: raw writes to a socket the peer has closed raise
// SIGPIPE and kill the process by default on Darwin. SO_NOSIGPIPE on the fd
// (plus a process-wide `signal(SIGPIPE, SIG_IGN)` belt-and-suspenders in
// `main`) turns that into an ordinary EPIPE delivered through the write
// completion handler instead of a crash. This is exactly the failure mode hit
// while exercising this probe: see FINDINGS.md.
final class LineSocket {
    private let fd: Int32
    private var channel: DispatchIO!
    private var buffer = Data()
    private let queue: DispatchQueue
    private var closed = false

    /// Invoked on `queue` for every complete line (newline stripped).
    var onLine: ((Data) -> Void)?
    /// Invoked on `queue` once when the read side reaches EOF or an error.
    /// `error` is the errno DispatchIO reported, 0 for a clean EOF.
    var onClose: ((Int32) -> Void)?

    init(path: String) throws {
        queue = DispatchQueue(label: "linesocket")
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var noSigPipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8CString) // includes trailing NUL
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            Foundation.close(fd)
            throw POSIXError(.ENAMETOOLONG)
        }
        pathBytes.withUnsafeBytes { pathRaw in
            withUnsafeMutableBytes(of: &addr.sun_path) { raw in
                raw.copyBytes(from: pathRaw)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
        }
        guard r == 0 else {
            let e = errno
            Foundation.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: e) ?? .EIO)
        }

        let localFd = fd
        channel = DispatchIO(type: .stream, fileDescriptor: fd, queue: queue) { _ in
            Foundation.close(localFd)
        }
        channel.setLimit(lowWater: 1)
        channel.read(offset: 0, length: .max, queue: queue) { [weak self] done, data, err in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(contentsOf: data)
                self.drainLines()
            }
            if done {
                self.onClose?(err)
            }
        }
    }

    private func drainLines() {
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[buffer.startIndex..<nl])
            buffer.removeSubrange(buffer.startIndex...nl)
            onLine?(line)
        }
    }

    /// `onWriteComplete` reports the errno DispatchIO's write handler saw
    /// (0 on success). Used by the single-connection burst probe to count
    /// how many sends actually succeeded before the peer went away.
    func send(_ line: String, onWriteComplete: ((Int32) -> Void)? = nil) {
        let payload = (line + "\n").data(using: .utf8)!
        payload.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let dd = DispatchData(bytes: raw)
            channel.write(offset: 0, data: dd, queue: queue) { _, _, err in
                onWriteComplete?(err)
            }
        }
    }

    /// Closes the channel abruptly (does not wait for in-flight reads). Used
    /// by Probe B to simulate a client disconnecting mid-stream.
    func closeAbruptly() {
        queue.sync {
            guard !closed else { return }
            closed = true
            channel.close(flags: .stop)
        }
    }

    var rawFD: Int32 { fd }
}

// MARK: - JSON helpers

func jsonRequestLine(id: String, method: String, params: [String: Any]) -> String {
    let obj: [String: Any] = ["id": id, "method": method, "params": params]
    let data = try! JSONSerialization.data(withJSONObject: obj)
    return String(data: data, encoding: .utf8)!
}

func parseJSONObject(_ data: Data) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

func jsonByteCount(_ obj: Any) -> Int {
    (try? JSONSerialization.data(withJSONObject: obj))?.count ?? 0
}

// MARK: - One-shot request: the pattern herdr's api socket actually requires.
// Opens a fresh connection, sends exactly one request, waits for exactly one
// response line (or timeout/EOF), closes the connection.

struct OneShotResult {
    var id: String
    var response: [String: Any]?
    var rawLine: Data?
    var timedOut: Bool = false
    var connectError: String?
}

func oneShotRequest(socketPath: String, id: String, method: String, params: [String: Any], timeout: TimeInterval = 5) -> OneShotResult {
    guard let sock = try? LineSocket(path: socketPath) else {
        return OneShotResult(id: id, response: nil, rawLine: nil, connectError: "connect failed")
    }
    let sem = DispatchSemaphore(value: 0)
    var line: Data?
    sock.onLine = { data in
        line = data
        sem.signal()
    }
    sock.onClose = { _ in sem.signal() }
    sock.send(jsonRequestLine(id: id, method: method, params: params))
    let waitResult = sem.wait(timeout: .now() + timeout)
    sock.closeAbruptly()
    if waitResult == .timedOut {
        return OneShotResult(id: id, response: nil, rawLine: nil, timedOut: true)
    }
    guard let line else {
        return OneShotResult(id: id, response: nil, rawLine: nil)
    }
    return OneShotResult(id: id, response: parseJSONObject(line), rawLine: line)
}

/// Runs `oneShotRequest` for every entry in `reqs`, `concurrency` at a time.
func runConcurrentOneShots(socketPath: String, reqs: [(id: String, method: String, params: [String: Any])], concurrency: Int) -> [String: OneShotResult] {
    let lock = NSLock()
    var results: [String: OneShotResult] = [:]
    results.reserveCapacity(reqs.count)
    let sema = DispatchSemaphore(value: concurrency)
    let group = DispatchGroup()
    let q = DispatchQueue(label: "oneshot.pool", attributes: .concurrent)
    for r in reqs {
        sema.wait()
        q.async(group: group) {
            let result = oneShotRequest(socketPath: socketPath, id: r.id, method: r.method, params: r.params)
            lock.lock()
            results[r.id] = result
            lock.unlock()
            sema.signal()
        }
    }
    group.wait()
    return results
}

// MARK: - Shared result tracking

var failures: [String] = []
func check(_ ok: Bool, _ label: String) {
    let mark = ok ? "PASS" : "FAIL"
    print("[\(mark)] \(label)")
    if !ok { failures.append(label) }
}
func note(_ label: String) {
    print("[NOTE] \(label)")
}

// MARK: - Probe A: request/response correctness

func runProbeA(socketPath: String) {
    print("=== Probe A: request/response correctness ===")

    // --- Part 1: literal brief scenario. ping, session.snapshot, and a burst
    // of pane.get, all on ONE connection. Exploratory testing against this
    // real herdr (see FINDINGS.md) showed the api socket serves exactly one
    // request per connection and then closes it, so this is expected to fail
    // starting at the second request; the point is to record precisely how.
    print("--- Part 1: as specified in the brief (one connection for everything) ---")
    guard let lit = try? LineSocket(path: socketPath) else {
        check(false, "connect literal-single-connection probe to \(socketPath)")
        return
    }
    var litLines: [Data] = []
    let litLock = NSLock()
    let litFirstLineSem = DispatchSemaphore(value: 0)
    var litClosed: Int32?
    let litCloseSem = DispatchSemaphore(value: 0)
    lit.onLine = { line in
        litLock.lock(); litLines.append(line); litLock.unlock()
        litFirstLineSem.signal()
    }
    lit.onClose = { err in
        litClosed = err
        litCloseSem.signal()
    }

    lit.send(jsonRequestLine(id: "lit-ping", method: "ping", params: [:]))
    _ = litFirstLineSem.wait(timeout: .now() + 3)
    let pingOnLitOk = litLock.withLock { !litLines.isEmpty }
    check(pingOnLitOk, "ping answered on the shared connection (request #1)")

    var snapWriteErr: Int32?
    let snapWriteSem = DispatchSemaphore(value: 0)
    lit.send(jsonRequestLine(id: "lit-snap", method: "session.snapshot", params: [:])) { err in
        snapWriteErr = err
        snapWriteSem.signal()
    }
    _ = snapWriteSem.wait(timeout: .now() + 3)
    // Give a bit more time in case a response line trickles in anyway.
    Thread.sleep(forTimeInterval: 0.3)
    litLock.lock()
    let linesAfterSnap = litLines.count
    litLock.unlock()
    let snapGotResponse = linesAfterSnap >= 2

    var burstWriteOK = 0
    var burstWriteFail = 0
    let burstLock = NSLock()
    let burstCount = 1000
    for i in 0..<burstCount {
        lit.send(jsonRequestLine(id: "lit-get-\(i)", method: "pane.get", params: ["pane_id": "w1:p1"])) { err in
            burstLock.lock()
            if err == 0 { burstWriteOK += 1 } else { burstWriteFail += 1 }
            burstLock.unlock()
        }
    }
    Thread.sleep(forTimeInterval: 1.0)
    litLock.lock()
    let totalLinesOnLit = litLines.count
    litLock.unlock()
    burstLock.lock()
    let finalWriteOK = burstWriteOK
    let finalWriteFail = burstWriteFail
    burstLock.unlock()

    let asSpecifiedWorks = snapGotResponse && (finalWriteFail == 0) && (totalLinesOnLit >= 1 + 1 + burstCount)
    check(asSpecifiedWorks, "single shared connection answers ping + session.snapshot + \(burstCount)x pane.get, all with distinct ids (as literally specified)")
    note("single-connection evidence: request #1 (ping) answered = \(pingOnLitOk); request #2 (session.snapshot) got a response = \(snapGotResponse) (write errno=\(snapWriteErr ?? -1)); of \(burstCount) queued pane.get writes, \(finalWriteOK) completed without a local write error and \(finalWriteFail) failed locally; total response lines ever seen on this connection = \(totalLinesOnLit) (expected \(2 + burstCount) if multiplexing worked); onClose fired with errno \(String(describing: litClosed))")
    lit.closeAbruptly()
    _ = litCloseSem.wait(timeout: .now() + 1)

    // --- Part 2: the pattern that actually works: one connection per
    // request. This is what Task 11's client must implement, and it is what
    // the pass/fail criteria below are actually verified against.
    print("--- Part 2: verified pattern (one connection per request) ---")
    let ping = oneShotRequest(socketPath: socketPath, id: "ping-1", method: "ping", params: [:])
    check(ping.response?["result"] != nil, "ping answered: \(String(describing: ping.response))")

    let multibyteLabel = "spike├──┐ 界 café naïve 🚀"
    let wsResult = oneShotRequest(socketPath: socketPath, id: "ws-1", method: "workspace.create",
                                   params: ["cwd": "/tmp", "label": multibyteLabel])
    guard let rootPane = ((wsResult.response?["result"] as? [String: Any])?["root_pane"] as? [String: Any])?["pane_id"] as? String else {
        check(false, "workspace.create for multibyte probe: \(String(describing: wsResult.response))")
        return
    }

    let snap = oneShotRequest(socketPath: socketPath, id: "snap-1", method: "session.snapshot", params: [:])
    let snapRawStr = snap.rawLine.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    check(snapRawStr.contains(multibyteLabel), "multibyte label (box-drawing/CJK/emoji) round-trips intact through session.snapshot")
    check(snap.response != nil, "session.snapshot answered")

    let n = 1000
    var reqs: [(id: String, method: String, params: [String: Any])] = []
    reqs.reserveCapacity(n)
    for i in 0..<n {
        reqs.append((id: "get-\(i)", method: "pane.get", params: ["pane_id": rootPane]))
    }
    let burstStart = Date()
    let results = runConcurrentOneShots(socketPath: socketPath, reqs: reqs, concurrency: 32)
    let burstMs = Date().timeIntervalSince(burstStart) * 1000

    let missing = reqs.filter { results[$0.id] == nil }
    check(missing.isEmpty, "every one-shot connection produced a result object (missing: \(missing.count))")

    var idMismatches = 0
    var parseFailures = 0
    var wrongPane = 0
    for r in reqs {
        guard let result = results[r.id] else { continue }
        guard let resp = result.response else { parseFailures += 1; continue }
        guard let respId = resp["id"] as? String, respId == r.id else { idMismatches += 1; continue }
        let paneId = ((resp["result"] as? [String: Any])?["pane"] as? [String: Any])?["pane_id"] as? String
        if paneId != rootPane { wrongPane += 1 }
    }
    check(parseFailures == 0, "every response parsed as JSON (parse failures: \(parseFailures))")
    check(idMismatches == 0, "every response id matched the request id it was sent for (mismatches: \(idMismatches))")
    check(wrongPane == 0, "every pane.get response named the correct pane_id (wrong: \(wrongPane))")
    print("Probe A part 2: \(n) one-shot requests, concurrency 32, \(String(format: "%.0f", burstMs))ms total, \(String(format: "%.3f", burstMs / Double(n)))ms/req avg")
}

// MARK: - Probe B: subscription stream + cancellation

func runSeedLayoutScript(socketPath: String, scriptPath: String) -> [String: Any]? {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/bash")
    task.arguments = [scriptPath, socketPath]
    let pipe = Pipe()
    task.standardOutput = pipe
    do {
        try task.run()
    } catch {
        print("[FAIL] could not run seed-layout.sh: \(error)")
        return nil
    }
    task.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return parseJSONObject(data)
}

func shell(_ command: String) -> String {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/bash")
    task.arguments = ["-c", command]
    let pipe = Pipe()
    task.standardOutput = pipe
    try? task.run()
    task.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8) ?? ""
}

/// Side experiment on its own disposable connection: does sending a second
/// request on an events.subscribe connection get answered, or does it just
/// get ignored? Answer (see FINDINGS.md): the server tears the connection
/// down, so this must never share a connection with the real subscriber used
/// for the rest of Probe B.
func probeSecondRequestOnSubscribeConnection(socketPath: String) {
    guard let throwaway = try? LineSocket(path: socketPath) else {
        note("second-request-on-subscribe experiment: could not connect")
        return
    }
    var lines: [Data] = []
    let lock = NSLock()
    let ackSem = DispatchSemaphore(value: 0)
    var closedCode: Int32?
    let closeSem = DispatchSemaphore(value: 0)
    throwaway.onLine = { line in
        lock.lock(); lines.append(line); lock.unlock()
        ackSem.signal()
    }
    throwaway.onClose = { err in
        closedCode = err
        closeSem.signal()
    }
    throwaway.send(jsonRequestLine(id: "sub-side", method: "events.subscribe",
                                    params: ["subscriptions": [["type": "layout.updated"]]]))
    _ = ackSem.wait(timeout: .now() + 3)
    throwaway.send(jsonRequestLine(id: "ping-on-sub", method: "ping", params: [:]))
    let closedAfterSecondRequest = closeSem.wait(timeout: .now() + 2) == .success
    let linesAfterSecondRequest = lock.withLock { lines.count }
    throwaway.closeAbruptly()
    note("second request on a subscribe connection: connection closed = \(closedAfterSecondRequest) (errno \(String(describing: closedCode))), total lines ever received = \(linesAfterSecondRequest) (expected 1, the ack only; sending anything else on a subscribe connection tears it down)")
}

func runProbeB(socketPath: String, seedScriptPath: String) {
    print("=== Probe B: subscription stream + cancellation ===")

    probeSecondRequestOnSubscribeConnection(socketPath: socketPath)

    guard let sub = try? LineSocket(path: socketPath) else {
        check(false, "connect subscriber to \(socketPath)")
        return
    }
    var subLines: [(t: Double, bytes: Int, data: Data)] = []
    let subLock = NSLock()
    let t0 = DispatchTime.now().uptimeNanoseconds
    let ackSem = DispatchSemaphore(value: 0)
    var ackLine: Data?
    var gotAck = false
    sub.onLine = { line in
        let now = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000_000
        subLock.lock()
        subLines.append((now, line.count, line))
        subLock.unlock()
        if !gotAck {
            gotAck = true
            ackLine = line
            ackSem.signal()
        }
    }
    var closedCode: Int32?
    let closeSem = DispatchSemaphore(value: 0)
    sub.onClose = { err in
        closedCode = err
        closeSem.signal()
    }

    sub.send(jsonRequestLine(id: "sub-1", method: "events.subscribe",
                              params: ["subscriptions": [["type": "layout.updated"], ["type": "pane.updated"]]]))
    _ = ackSem.wait(timeout: .now() + 3)
    let ackObj = ackLine.flatMap(parseJSONObject)
    let ackType = ((ackObj?["result"] as? [String: Any])?["type"] as? String)
    check(ackType == "subscription_started", "events.subscribe ack: \(String(describing: ackObj))")

    // Burst 1 and 2: two independent seed-layout.sh runs (each opens its own
    // one-shot connections via nc internally).
    let seed1 = runSeedLayoutScript(socketPath: socketPath, scriptPath: seedScriptPath)
    check(seed1 != nil, "seed-layout.sh run 1 produced output: \(String(describing: seed1))")
    let seed2 = runSeedLayoutScript(socketPath: socketPath, scriptPath: seedScriptPath)
    check(seed2 != nil, "seed-layout.sh run 2 produced output: \(String(describing: seed2))")

    // Grow one tab past 64KB of layout.updated payload: alternate right/down
    // splits on a single pane chain, each split its own one-shot connection.
    let wsResult = oneShotRequest(socketPath: socketPath, id: "big-ws", method: "workspace.create",
                                   params: ["cwd": "/tmp", "label": "bigsplit"])
    guard let bigPane0 = ((wsResult.response?["result"] as? [String: Any])?["root_pane"] as? [String: Any])?["pane_id"] as? String else {
        check(false, "workspace.create for split-growth probe: \(String(describing: wsResult.response))")
        return
    }
    var currentPane = bigPane0
    var splitSizesAtCheckpoints: [(Int, Int)] = [] // (split count, max observed layout.updated bytes so far)
    let splitTargetCount = 150 // see FINDINGS.md for the measured growth curve vs. the brief's suggested 12
    var eventLagSamplesMs: [Double] = []
    for i in 0..<splitTargetCount {
        let dir = (i % 2 == 0) ? "right" : "down"
        let linesBefore = subLock.withLock { subLines.count }
        let responseReceivedAt = Date()
        let resp = oneShotRequest(socketPath: socketPath, id: "split-\(i)", method: "pane.split",
                                   params: ["target_pane_id": currentPane, "direction": dir])
        guard let newPane = ((resp.response?["result"] as? [String: Any])?["pane"] as? [String: Any])?["pane_id"] as? String else {
            print("[WARN] split \(i) did not return a pane id, stopping split growth early: \(String(describing: resp.response))")
            break
        }
        currentPane = newPane
        if (i + 1) % 20 == 0 {
            // Poll briefly for the event this split should trigger, to
            // estimate propagation latency against the 100ms server poll.
            var lagMs: Double?
            let deadline = Date().addingTimeInterval(0.5)
            while Date() < deadline {
                if subLock.withLock({ subLines.count }) > linesBefore {
                    lagMs = Date().timeIntervalSince(responseReceivedAt) * 1000
                    break
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
            if let lagMs { eventLagSamplesMs.append(lagMs) }
        }
        if (i + 1) % 10 == 0 {
            let maxSoFar = subLock.withLock { subLines.map(\.bytes).max() ?? 0 }
            splitSizesAtCheckpoints.append((i + 1, maxSoFar))
        }
    }
    print("event propagation lag samples (ms, response-received to event-observed): \(eventLagSamplesMs.map { String(format: "%.1f", $0) })")

    // Give the 100ms server poll time to flush the last few events, then
    // pull a session.snapshot as the large-line fallback per the brief.
    Thread.sleep(forTimeInterval: 0.5)
    let bigSnap = oneShotRequest(socketPath: socketPath, id: "big-snap", method: "session.snapshot", params: [:])
    let bigSnapBytes = bigSnap.response.map(jsonByteCount) ?? 0

    let lines = subLock.withLock { subLines }
    let maxEventLine = lines.max(by: { $0.bytes < $1.bytes })
    check(!lines.isEmpty, "subscriber received \(lines.count) event lines across both seed runs + split growth")
    print("layout.updated size growth by split count: \(splitSizesAtCheckpoints)")

    let over64k = lines.filter { $0.bytes > 65536 }
    if let maxEventLine, maxEventLine.bytes > 65536 {
        check(true, "a subscription event line exceeded 64KB unfragmented (\(maxEventLine.bytes) bytes, \(over64k.count) such lines total, out of \(splitTargetCount) splits)")
    } else {
        check(bigSnapBytes > 65536, "subscription event lines stayed under 64KB (max \(maxEventLine?.bytes ?? 0) bytes over \(splitTargetCount) splits); falling back to session.snapshot per the brief's fallback clause: snapshot is \(bigSnapBytes) bytes")
    }

    // Ordering: timestamps recorded as lines arrive must be non-decreasing
    // (LineSocket appends strictly in read order), and each parsed line must
    // carry a recognizable event/id field.
    var timestampsOrdered = true
    var last = -1.0
    var unrecognizedEventLines = 0
    for l in lines {
        if l.t < last { timestampsOrdered = false }
        last = l.t
        guard let obj = parseJSONObject(l.data), obj["event"] != nil || obj["id"] != nil else {
            unrecognizedEventLines += 1
            continue
        }
    }
    check(timestampsOrdered, "event lines arrived in non-decreasing time order (no reordering by DispatchIO)")
    check(unrecognizedEventLines == 0, "every subscriber line parses as JSON with an event/id field (unrecognized: \(unrecognizedEventLines))")

    // Cancellation: close the subscriber connection abruptly, mid-stream,
    // and confirm the read callback ends cleanly with no crash.
    let fdBefore = sub.rawFD
    sub.closeAbruptly()
    let closedInTime = closeSem.wait(timeout: .now() + 3) == .success
    check(closedInTime, "read callback observed close/EOF after abrupt disconnect (code: \(String(describing: closedCode)))")

    let lsofOutput = shell("lsof -p \(getpid()) 2>/dev/null | grep -c '\(fdBefore)u'")
    let leakedCount = Int(lsofOutput.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
    check(leakedCount == 0, "fd \(fdBefore) not present in lsof after close (matches found: \(leakedCount))")

    print("Probe B: \(lines.count) event lines, max \(maxEventLine?.bytes ?? 0) bytes, big snapshot \(bigSnapBytes) bytes")
}

extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

// MARK: - Entry point

signal(SIGPIPE, SIG_IGN)

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: FlockSocketSpike <probeA|probeB> <socket-path> [seed-layout-script-path]")
    exit(2)
}
let mode = args[1]
let socketPath = args[2]

switch mode {
case "probeA":
    runProbeA(socketPath: socketPath)
case "probeB":
    guard args.count >= 4 else {
        print("usage: FlockSocketSpike probeB <socket-path> <seed-layout-script-path>")
        exit(2)
    }
    runProbeB(socketPath: socketPath, seedScriptPath: args[3])
default:
    print("unknown mode \(mode)")
    exit(2)
}

print("---")
if failures.isEmpty {
    print("ALL CHECKS PASSED")
    exit(0)
} else {
    print("\(failures.count) CHECK(S) FAILED:")
    for f in failures { print("  - \(f)") }
    exit(1)
}
