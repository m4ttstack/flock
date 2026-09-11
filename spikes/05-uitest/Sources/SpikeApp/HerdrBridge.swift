import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Fires the herdr closed-loop call on a successful drop, iff the three env
/// vars a UI test's launchEnvironment supplies are present (step 1's test
/// never sets them, so step 1 runs never touch herdr at all).
enum HerdrBridge {
    static func notifyDropIfConfigured() {
        let env = ProcessInfo.processInfo.environment
        guard let socketPath = env["HERDR_SOCKET_PATH"],
              let paneID = env["SPIKE_PANE_ID"],
              let wsID = env["SPIKE_WS_ID"] else { return }

        // Off the main thread: a unix socket round trip is fast, but nothing
        // about this drop handler should block gesture delivery.
        DispatchQueue.global(qos: .userInitiated).async {
            let requestObj: [String: Any] = [
                "id": "drop1",
                "method": "pane.move",
                "params": [
                    "pane_id": paneID,
                    "destination": [
                        "type": "new_tab",
                        "workspace_id": wsID,
                        "label": "dropped",
                    ],
                    "focus": false,
                ],
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: requestObj),
                  var line = String(data: data, encoding: .utf8) else { return }
            line += "\n"

            let response = sendOneShot(socketPath: socketPath, line: line)
            // Debug trail only; the UI test verifies the effect independently
            // via its own session.snapshot connection, never by reading this.
            try? response.write(toFile: "/tmp/spike-herdr-response.json", atomically: true, encoding: .utf8)
        }
    }

    /// herdr's api socket answers exactly one request per connection then
    /// closes it (spikes/02-socket/FINDINGS.md); this opens one connection,
    /// writes one line, reads one line, and closes -- never reused.
    private static func sendOneShot(socketPath: String, line: String) -> String {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return "{\"error\":\"socket() failed errno=\(errno)\"}" }
        defer { Foundation.close(fd) }

        var noSigPipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            return "{\"error\":\"socket path too long\"}"
        }
        pathBytes.withUnsafeBytes { raw in
            withUnsafeMutableBytes(of: &addr.sun_path) { dest in
                dest.copyBytes(from: raw)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
        }
        guard connected == 0 else { return "{\"error\":\"connect() failed errno=\(errno)\"}" }

        _ = line.withCString { write(fd, $0, strlen($0)) }

        var buffer = [UInt8](repeating: 0, count: 65536)
        var collected = Data()
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            collected.append(contentsOf: buffer[0..<n])
            if collected.contains(0x0A) { break }
        }
        return String(data: collected, encoding: .utf8) ?? "{\"error\":\"no response\"}"
    }
}
