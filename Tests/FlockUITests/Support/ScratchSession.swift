import Darwin
import Foundation

/// The ids `Support/bin/seed-layout.sh` produces: one workspace, `tabA`
/// holding `p1` and `p2` side by side, `tabB` holding `p3` alone.
struct SeedIDs {
    let ws: String
    let tabA: String
    let tabB: String
    let p1: String
    let p2: String
    let p3: String
}

struct ScratchSessionError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// One request the app sent through the fault proxy, with herdr's reply to it.
///
/// Times are milliseconds from the moment the proxy started recording, which
/// is what separates two verbs of one plan from two plans: the second op of a
/// composition follows its first by a millisecond or so, while a later gesture
/// is seconds away.
struct ProxyExchange: CustomStringConvertible {
    /// What herdr said back. Every case is distinct on purpose: a verb that
    /// was never answered, one whose answer could not be read, one herdr
    /// refused and one that did something are four different findings, and
    /// folding any two of them together is how "the app never sent it" gets
    /// mistaken for "herdr said no".
    enum Answer: Equatable {
        /// Nothing came back before the connection ended. The proxy records a
        /// reply as it relays it, so this is also what a caller that hung up
        /// without reading its own answer leaves behind.
        case none
        case unreadable(String)
        case error(code: String, message: String)
        case refused(String)
        case ok
    }

    let method: String?
    let id: String?
    let request: String
    let requestAtMilliseconds: Double
    let reply: String?
    let replyAtMilliseconds: Double?
    let replyTruncated: Bool

    init(row: [String: Any]) {
        method = row["method"] as? String
        id = row["id"] as? String
        request = row["request"] as? String ?? ""
        requestAtMilliseconds = (row["requestAt"] as? NSNumber)?.doubleValue ?? 0
        reply = row["reply"] as? String
        replyAtMilliseconds = (row["replyAt"] as? NSNumber)?.doubleValue
        replyTruncated = row["replyTruncated"] as? Bool ?? false
    }

    /// The request's own `params`, or nil when the line was not a request this
    /// proxy could read (the pane bridges the app spawns share the socket and
    /// speak their own protocol over it).
    var params: [String: Any]? { Self.object(request)?["params"] as? [String: Any] }

    /// One step down into `params`, for the nested `destination` a `pane.move`
    /// carries.
    func param(_ path: String...) -> Any? {
        var current: Any? = params
        for key in path {
            guard let step = (current as? [String: Any])?[key] else { return nil }
            current = step
        }
        return current
    }

    /// herdr answers a verb it declined with a success envelope carrying a
    /// `reason` rather than with an error, so both shapes are read here: the
    /// reason lives one level inside `result` (`move_result.reason`,
    /// `swap.reason`), beside the `changed` flag it explains.
    var answer: Answer {
        guard let reply else { return .none }
        if replyTruncated { return .unreadable("the reply was longer than the proxy records") }
        guard let object = Self.object(reply) else { return .unreadable("the reply was not a JSON object") }
        if let error = object["error"] as? [String: Any] {
            return .error(
                code: error["code"] as? String ?? "unknown",
                message: error["message"] as? String ?? ""
            )
        }
        guard let result = object["result"] as? [String: Any] else {
            return .unreadable("the reply carried neither a result nor an error")
        }
        for value in result.values {
            if let payload = value as? [String: Any], let reason = payload["reason"] as? String {
                return .refused(reason)
            }
        }
        return .ok
    }

    /// The `changed` flag herdr's reply carries beside the `reason` that
    /// explains a false one, or nil for a verb whose reply carries neither
    /// (`pane.focus` and the other acknowledgements) and for a reply that
    /// could not be read.
    ///
    /// Read separately from `answer` because the two say different things: a
    /// verb herdr accepted and then did nothing about answers `.ok` with
    /// `changed` false, and a composition whose second op is a no-op is
    /// exactly the failure that would otherwise read as a pass.
    var changed: Bool? { resultPayload?["changed"] as? Bool }

    /// The pane rects herdr's own reply carries for the tab the verb changed:
    /// `pane.swap` answers with that tab's whole `layout`, `pane.move` with
    /// the destination's `target_layout`.
    ///
    /// This is herdr's word for what the verb itself did, and a snapshot taken
    /// afterwards is not the same claim: everything that happened in between
    /// is in the snapshot and not in here, which is what separates a verb that
    /// did the wrong thing from a verb something else undid.
    func replyPaneRects() -> [String: HerdrRect]? {
        guard let layout = (resultPayload?["layout"] ?? resultPayload?["target_layout"]) as? [String: Any],
              let panes = layout["panes"] as? [[String: Any]] else {
            return nil
        }
        var rects: [String: HerdrRect] = [:]
        for pane in panes {
            guard let id = pane["pane_id"] as? String, let rect = pane["rect"] as? [String: Any],
                  let x = (rect["x"] as? NSNumber)?.intValue, let y = (rect["y"] as? NSNumber)?.intValue,
                  let width = (rect["width"] as? NSNumber)?.intValue,
                  let height = (rect["height"] as? NSNumber)?.intValue else {
                continue
            }
            rects[id] = HerdrRect(x: x, y: y, width: width, height: height)
        }
        return rects.isEmpty ? nil : rects
    }

    /// herdr nests each verb's own result one level inside `result`, under a
    /// key named for the verb (`move_result`, `swap`) beside a `type` that
    /// names it again, so the payload is the one object in there.
    private var resultPayload: [String: Any]? {
        guard let reply, !replyTruncated, let object = Self.object(reply),
              let result = object["result"] as? [String: Any] else {
            return nil
        }
        return result.values.compactMap { $0 as? [String: Any] }.first
    }

    var description: String {
        let name = method ?? "<not a request>"
        let stamp = String(format: "%.1fms", requestAtMilliseconds)
        let answered = replyAtMilliseconds.map { String(format: " answered +%.1fms", $0 - requestAtMilliseconds) } ?? ""
        let did = changed.map { " changed=\($0)" } ?? ""
        let rects = replyPaneRects().map { " rects=\(Self.rectDigest($0))" } ?? ""
        return "\(stamp) \(name)\(id.map { " id=\($0)" } ?? "") -> \(answer)\(did)\(answered)\(rects) "
            + "params=\(Self.digest(params))"
    }

    private static func rectDigest(_ rects: [String: HerdrRect]) -> String {
        "[" + rects.keys.sorted().map { "\($0)@x=\(rects[$0]!.x)" }.joined(separator: " ") + "]"
    }

    private static func object(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func digest(_ params: [String: Any]?) -> String {
        guard let params,
              let data = try? JSONSerialization.data(withJSONObject: params, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "<none>"
        }
        return text.count <= 240 ? text : String(text.prefix(240)) + "..."
    }
}

extension Array where Element == ProxyExchange {
    /// Every exchange on its own line, for a failure message: what actually
    /// left the app is the whole point of recording it, so a case that fails
    /// here says so rather than leaving the next run to find out.
    func outline() -> String {
        isEmpty ? "the app sent nothing through the proxy" : "\n" + map { "  \($0)" }.joined(separator: "\n")
    }
}

/// The test bundle's end of the e2e harness: a ground-truth channel into the
/// herdr session `Scripts/e2e.sh` created for this run, independent of the app
/// under test.
///
/// Nothing here touches herdr's socket directly, and not by preference. Xcode
/// hosts every macOS UI-testing bundle in a `-Runner.app` it sandboxes
/// unconditionally, and that sandbox denies `connect()` on any unix socket
/// outside the container: `nc -U` exits 1 with no message and a native
/// AF_UNIX connect returns EPERM, whether the caller is this bundle or a
/// process it spawned. Outbound TCP to loopback IS permitted, so every request
/// below goes to `Support/bin/e2e-bridge.py`, which the wrapper runs outside
/// the sandbox, and which forwards to herdr and performs the two session
/// operations no sandboxed process can.
///
/// One session serves a whole `xcodebuild test` invocation, so a case that
/// leaves the layout changed would hand the next case a dirty world. Call
/// `reseed()` in `setUpWithError` to start from the canonical seed; herdr
/// numbers a fresh session's ids from one, so `seedIDs()` stays correct across
/// a reseed.
final class ScratchSession {
    let socketPath: String
    private let ids: SeedIDs
    private let bridgePort: UInt16
    private let bridgeToken: String

    private init(socketPath: String, ids: SeedIDs, bridgePort: UInt16, bridgeToken: String) {
        self.socketPath = socketPath
        self.ids = ids
        self.bridgePort = bridgePort
        self.bridgeToken = bridgeToken
    }

    static func attachFromEnvironment() throws -> ScratchSession {
        let environment = ProcessInfo.processInfo.environment
        func present(_ key: String) -> String? {
            guard let value = environment[key], !value.isEmpty else { return nil }
            return value
        }
        guard let socketPath = present("FLOCK_SOCKET") else {
            throw ScratchSessionError(
                "FLOCK_SOCKET is unset. Run this suite through Scripts/e2e.sh: xcodebuild on its own boots no herdr session."
            )
        }
        guard let rawPort = present("FLOCK_BRIDGE_PORT"), let port = UInt16(rawPort) else {
            throw ScratchSessionError(
                "FLOCK_BRIDGE_PORT is unset or not a port: \(present("FLOCK_BRIDGE_PORT") ?? "<unset>")"
            )
        }
        guard let token = present("FLOCK_BRIDGE_TOKEN") else {
            throw ScratchSessionError("FLOCK_BRIDGE_TOKEN is unset; the bridge refuses every request without it")
        }
        guard let seed = present("FLOCK_SEED_IDS"), let data = seed.data(using: .utf8),
              let map = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] else {
            throw ScratchSessionError(
                "FLOCK_SEED_IDS is not a JSON object of ids: \(present("FLOCK_SEED_IDS") ?? "<unset>")"
            )
        }
        func id(_ key: String) throws -> String {
            guard let value = map[key], !value.isEmpty else {
                throw ScratchSessionError("FLOCK_SEED_IDS carries no \(key): \(map)")
            }
            return value
        }
        return ScratchSession(
            socketPath: socketPath,
            ids: SeedIDs(
                ws: try id("ws"), tabA: try id("tabA"), tabB: try id("tabB"),
                p1: try id("p1"), p2: try id("p2"), p3: try id("p3")
            ),
            bridgePort: port,
            bridgeToken: token
        )
    }

    func seedIDs() -> SeedIDs { ids }

    func snapshot() throws -> HerdrSnapshotJSON {
        let response = try request(#"{"id":"e2e-snapshot","method":"session.snapshot","params":{}}"#)
        guard let result = response["result"] as? [String: Any],
              let snapshot = result["snapshot"] as? [String: Any] else {
            throw ScratchSessionError("session.snapshot carried no snapshot: \(response)")
        }
        return HerdrSnapshotJSON(snapshot)
    }

    /// Polls until the session says what the caller is waiting for, and
    /// returns that snapshot. A gesture reaches herdr through an RPC and comes
    /// back through an event, so nothing a drop does is visible in the instant
    /// the drop finished; reading once would test the timing rather than the
    /// drop.
    ///
    /// A timeout names what was expected AND what herdr was actually holding:
    /// a case authored against a layout that never arrived is otherwise
    /// indistinguishable from a gesture that missed its target.
    func snapshot(
        waitingFor expectation: String, timeout: TimeInterval = 20, until condition: (HerdrSnapshotJSON) -> Bool
    ) throws -> HerdrSnapshotJSON {
        let deadline = Date().addingTimeInterval(timeout)
        var latest: HerdrSnapshotJSON?
        while Date() < deadline {
            let current = try snapshot()
            latest = current
            if condition(current) { return current }
            usleep(100_000)
        }
        throw ScratchSessionError(
            "timed out after \(timeout)s waiting for \(expectation). herdr holds: "
                + (latest?.outline() ?? "<no snapshot answered>")
        )
    }

    /// Changes the world the app is mirroring without going through the app,
    /// so a case can assert on what the app does with a change it did not
    /// make. Throws on a herdr error response rather than letting a rejected
    /// request read as a mutation that landed.
    func mutate(_ requestLine: String) throws {
        _ = try request(requestLine)
    }

    /// The visible screen of a pane, as herdr reads it out of the terminal --
    /// the one ground truth for anything typed into the app, since a
    /// terminal's own content is nowhere in the accessibility tree.
    func paneText(_ paneID: String) throws -> String {
        let response = try request(
            #"{"id":"e2e-read","method":"pane.read","params":{"pane_id":"\#(paneID)","source":"visible"}}"#
        )
        // `result.read.text`: the screen is nested under a `pane_read` record
        // of its own, beside the pane's ids and the revision it was read at.
        guard let result = response["result"] as? [String: Any],
              let read = result["read"] as? [String: Any],
              let text = read["text"] as? String else {
            throw ScratchSessionError("pane.read on \(paneID) carried no text: \(response)")
        }
        return text
    }

    /// Stops only the server process and brings it back on the same session
    /// directory, so the state it was holding is what it comes back to.
    func restartServer() throws {
        try control("restart-server")
        try awaitLiveServer()
    }

    /// A unix socket that relays to the session's own and can cut one of the
    /// app's connections mid-flight, returned as the path to launch the app
    /// against in place of `socketPath`. Nothing else in a case goes through
    /// it: the ground truth read here still comes from herdr directly.
    ///
    /// It also starts the recording the app's traffic lands in, clearing
    /// whatever the previous case left there.
    func startFaultProxy() throws -> String {
        let result = try controlResult("fault-proxy-start")
        guard let path = result["socket"] as? String, !path.isEmpty else {
            throw ScratchSessionError("fault-proxy-start carried no socket path: \(result)")
        }
        return path
    }

    /// Arms a one-shot cut: the next `session.snapshot` the app sends through
    /// the proxy closes the app's blanket subscription connection first, and
    /// is answered only afterwards. Arm it BEFORE the app launches -- the
    /// bootstrap is the window this reproduces, and it is over in
    /// milliseconds.
    func armSubscriptionCut() throws {
        try control("fault-proxy-arm-subscription-cut")
    }

    /// How many subscription connections the proxy has actually cut. A case
    /// that asserts recovery has to check this: an arm that never fired
    /// leaves an ordinary launch, which converges whether or not the app
    /// handles the fault.
    func faultProxyCutCount() throws -> Int {
        let result = try controlResult("fault-proxy-report")
        guard let cuts = result["cuts"] as? Int else {
            throw ScratchSessionError("fault-proxy-report carried no cut count: \(result)")
        }
        return cuts
    }

    /// Every request the app sent through the fault proxy since it was
    /// started, in the order it sent them, each paired with herdr's reply.
    ///
    /// This is the only view of what the app itself asked for: herdr keeps no
    /// record of who asked it what, and a case reading the session afterwards
    /// sees the result of a plan without seeing the plan. A verb that never
    /// left the app and a verb herdr refused are the same layout from the
    /// outside, and they want opposite fixes.
    func faultProxyRecording() throws -> [ProxyExchange] {
        let result = try controlResult("fault-proxy-recording")
        guard let rows = result["exchanges"] as? [[String: Any]] else {
            throw ScratchSessionError("fault-proxy-recording carried no exchanges: \(result)")
        }
        return rows.map(ProxyExchange.init(row:))
    }

    /// A workspace on a throwaway git repo plus the linked-worktree workspace
    /// that makes the two a group herdr refuses to close one at a time. Both
    /// the repo and the checkout live in the wrapper's own work directory,
    /// which it removes with the run.
    ///
    /// The ids are returned rather than assumed: they follow whatever the
    /// session already holds, unlike the seed's, which a reseed makes stable.
    func seedWorktreeGroup() throws -> (primary: String, linked: String) {
        let result = try controlResult("seed-worktree-group")
        guard let primary = result["primary"] as? String, let linked = result["linked"] as? String else {
            throw ScratchSessionError("seed-worktree-group carried no workspace ids: \(result)")
        }
        return (primary, linked)
    }

    /// Destroys the session and rebuilds it from `seed-layout.sh`, which is
    /// how a case gets a pristine layout: the ids are the same afterward
    /// because herdr numbers a new session's workspaces, tabs and panes from
    /// one.
    func reseed() throws {
        try control("reseed-session")
        try awaitLiveServer()
        // The counts as well as the two tabs' contents: herdr numbers a fresh
        // session's ids from one, so a case that left `tabA` and `tabB` intact
        // and added a workspace or a third tab would satisfy the pane lists
        // alone and hand the next case its leftovers.
        try waitUntil(timeout: 20, "the reseeded session to carry the seed layout") {
            guard let snapshot = try? self.snapshot() else { return false }
            return snapshot.workspaceCount == 1
                && snapshot.tabCount(inWorkspace: self.ids.ws) == 2
                && snapshot.paneIDs(inTab: self.ids.tabA) == [self.ids.p1, self.ids.p2]
                && snapshot.paneIDs(inTab: self.ids.tabB) == [self.ids.p3]
        }
    }

    // MARK: - Bridge transport

    @discardableResult
    private func request(_ requestLine: String) throws -> [String: Any] {
        let reply = try bridge("herdr " + requestLine.trimmingCharacters(in: .newlines))
        guard let data = reply.data(using: .utf8),
              let response = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ScratchSessionError("herdr answered \(requestLine) with something that is not a JSON object: \(reply)")
        }
        if let error = response["error"] {
            throw ScratchSessionError("herdr rejected \(requestLine): \(error)")
        }
        return response
    }

    @discardableResult
    private func control(_ verb: String) throws -> [String: Any] {
        let reply = try bridge("control " + verb)
        guard let data = reply.data(using: .utf8),
              let response = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ScratchSessionError("the bridge answered \(verb) with something that is not a JSON object: \(reply)")
        }
        if let error = response["error"] {
            throw ScratchSessionError("the bridge could not \(verb): \(error)")
        }
        return response
    }

    /// A control verb whose helper produces ids rather than only an outcome.
    private func controlResult(_ verb: String) throws -> [String: Any] {
        let response = try control(verb)
        guard let result = response["result"] as? [String: Any] else {
            throw ScratchSessionError("\(verb) answered without a result: \(response)")
        }
        return result
    }

    /// A control verb takes the server down and brings it back, so the session
    /// is usable again only once a request actually answers.
    private func awaitLiveServer() throws {
        try waitUntil(timeout: 30, "the scratch server to answer again") {
            (try? self.snapshot()) != nil
        }
    }

    private func waitUntil(timeout: TimeInterval, _ what: String, _ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            usleep(25_000)
        }
        throw ScratchSessionError("timed out after \(timeout)s waiting for \(what)")
    }

    /// Sends a line to the bridge verbatim, token included. Only the harness's
    /// own coverage of the token needs this; every other caller goes through
    /// `request` or `control`, which prepend it.
    func sendRawBridgeLine(_ line: String) throws -> String {
        try send(line)
    }

    private func bridge(_ line: String) throws -> String {
        try send(bridgeToken + " " + line)
    }

    /// One request per connection, one line each way. Every failure says which
    /// half it came from: reaching the bridge at all, or what the bridge said.
    private func send(_ line: String) throws -> String {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ScratchSessionError("could not make a socket for the e2e bridge: errno \(errno)")
        }
        defer { close(fd) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = bridgePort.bigEndian
        address.sin_addr.s_addr = UInt32(0x7f00_0001).bigEndian
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                Darwin.connect(fd, generic, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            throw ScratchSessionError(
                "could not reach the e2e bridge on 127.0.0.1:\(bridgePort): errno \(errno). Scripts/e2e.sh runs it; it is not running."
            )
        }

        var timeout = timeval(tv_sec: 60, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var outgoing = Array((line + "\n").utf8)
        var sent = 0
        while sent < outgoing.count {
            let written = outgoing.withUnsafeBytes { raw in
                write(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent)
            }
            guard written > 0 else {
                throw ScratchSessionError("the e2e bridge closed while \(line.prefix(60)) was being sent: errno \(errno)")
            }
            sent += written
        }

        var incoming = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while !incoming.contains(UInt8(ascii: "\n")) {
            let read = Darwin.read(fd, &buffer, buffer.count)
            if read < 0 {
                throw ScratchSessionError("the e2e bridge failed mid-reply to \(line.prefix(60)): errno \(errno)")
            }
            if read == 0 { break }
            incoming.append(contentsOf: buffer[0..<read])
        }
        let reply = String(decoding: incoming, as: UTF8.self)
            .split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        guard !reply.isEmpty else {
            throw ScratchSessionError("the e2e bridge answered \(line.prefix(60)) with nothing")
        }
        return reply
    }
}
