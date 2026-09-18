import XCTest
@testable import FlockCore
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

final class PaneControlChannelTests: XCTestCase {
    func testSendThenReadRoundTripsOverTheFIFO() throws {
        let channel = try XCTUnwrap(PaneControlChannel())
        defer { channel.close() }

        // A second, independent opener standing in for the bridge's own
        // `startControlPipe(at:)`; the FIFO already has a reader/writer held
        // open by `channel` itself, so this does not race ENXIO.
        let readerFD = open(channel.path, O_RDONLY | O_NONBLOCK)
        XCTAssertGreaterThanOrEqual(readerFD, 0)
        defer { close(readerFD) }

        channel.send(["type": "terminal.input", "bytes": "aGk="])

        let line = try waitForNonEmptyReadFromFIFO(readerFD)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: line.split(separator: 0x0A)[0]) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "terminal.input")
        XCTAssertEqual(object["bytes"] as? String, "aGk=")
    }

    /// Matches Herdglass's own `PaneControlChannel.scroll` wire shape
    /// (`Sources/HerdrClient/PaneControlChannel.swift`): `type`, `direction`,
    /// `lines`, and a `source` that defaults to `"wheel"`.
    func testScrollFramesTheExactHerdrWireShape() throws {
        let channel = try XCTUnwrap(PaneControlChannel())
        defer { channel.close() }
        let readerFD = open(channel.path, O_RDONLY | O_NONBLOCK)
        XCTAssertGreaterThanOrEqual(readerFD, 0)
        defer { close(readerFD) }

        channel.scroll(direction: .up, lines: 5)

        let line = try waitForNonEmptyReadFromFIFO(readerFD)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: line.split(separator: 0x0A)[0]) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "terminal.scroll")
        XCTAssertEqual(object["direction"] as? String, "up")
        XCTAssertEqual(object["lines"] as? Int, 5)
        XCTAssertEqual(object["source"] as? String, "wheel")
    }

    /// herdr drops (`terminal_sessions.rs`: "terminal.scroll lines must be
    /// greater than 0") any non-positive line count -- this type must never
    /// even send one.
    /// The nudge the surface sends when its grid moves carries no size of its
    /// own: a bridge that read one from here could tell herdr a size the PTY
    /// does not have.
    func testSyncSizeCarriesTheTypeAndNothingElse() throws {
        let channel = try XCTUnwrap(PaneControlChannel())
        defer { channel.close() }
        let readerFD = open(channel.path, O_RDONLY | O_NONBLOCK)
        XCTAssertGreaterThanOrEqual(readerFD, 0)
        defer { close(readerFD) }

        channel.syncSize()

        let line = try waitForNonEmptyReadFromFIFO(readerFD)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: line.split(separator: 0x0A)[0]) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "flock.sync_size")
        XCTAssertEqual(object.keys.count, 1)
    }

    func testScrollWithNonPositiveLinesIsANoOp() throws {
        let channel = try XCTUnwrap(PaneControlChannel())
        defer { channel.close() }
        let readerFD = open(channel.path, O_RDONLY | O_NONBLOCK)
        XCTAssertGreaterThanOrEqual(readerFD, 0)
        defer { close(readerFD) }

        channel.scroll(direction: .down, lines: 0)
        channel.scroll(direction: .down, lines: -3)

        usleep(50_000)
        var buffer = [UInt8](repeating: 0, count: 64)
        XCTAssertLessThanOrEqual(read(readerFD, &buffer, buffer.count), 0)
    }

    /// One `terminal.input` carrying one complete bracketed paste, which is
    /// the only shape herdr reads as a paste rather than as typed input
    /// (`src/server/pane_input.rs`'s `apply_terminal_attach_input`).
    func testPasteSendsOneCompleteBracketedPaste() throws {
        let channel = try XCTUnwrap(PaneControlChannel())
        defer { channel.close() }
        let readerFD = open(channel.path, O_RDONLY | O_NONBLOCK)
        XCTAssertGreaterThanOrEqual(readerFD, 0)
        defer { close(readerFD) }

        channel.paste("/tmp/shot.png")

        let line = try waitForNonEmptyReadFromFIFO(readerFD)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: line.split(separator: 0x0A)[0]) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "terminal.input")
        let bytes = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(object["bytes"] as? String)))
        XCTAssertEqual(bytes, Data("\u{1B}[200~/tmp/shot.png\u{1B}[201~".utf8))
    }

    func testPasteOfEmptyTextIsANoOp() throws {
        let channel = try XCTUnwrap(PaneControlChannel())
        defer { channel.close() }
        let readerFD = open(channel.path, O_RDONLY | O_NONBLOCK)
        XCTAssertGreaterThanOrEqual(readerFD, 0)
        defer { close(readerFD) }

        channel.paste("")

        usleep(50_000)
        var buffer = [UInt8](repeating: 0, count: 64)
        XCTAssertLessThanOrEqual(read(readerFD, &buffer, buffer.count), 0)
    }

    /// A paste is the one command here whose size the user picks, and the
    /// descriptor is non-blocking: a line longer than the FIFO's buffer has to
    /// wait for the reader rather than stop half written. Half a line would be
    /// swallowed by the next command, since the bridge splits on newlines.
    func testAPasteLargerThanTheFIFOBufferArrivesWhole() throws {
        let channel = try XCTUnwrap(PaneControlChannel())
        defer { channel.close() }
        let readerFD = open(channel.path, O_RDONLY | O_NONBLOCK)
        XCTAssertGreaterThanOrEqual(readerFD, 0)

        // Four times macOS's largest FIFO buffer, so the write cannot land in
        // one pass however the kernel sizes the pipe.
        let text = String(repeating: "0123456789abcdef", count: 16 * 1024)
        let collected = FIFOLineCollector()
        let drained = expectation(description: "the whole line arrives")
        Thread {
            var scratch = [UInt8](repeating: 0, count: 8192)
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline {
                let n = read(readerFD, &scratch, scratch.count)
                if n > 0 {
                    if collected.append(Data(scratch.prefix(n))) { break }
                    continue
                }
                usleep(1_000)
            }
            drained.fulfill()
        }.start()

        channel.paste(text)
        wait(for: [drained], timeout: 30)
        close(readerFD)

        let line = try XCTUnwrap(collected.line())
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: line) as? [String: Any])
        let bytes = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(object["bytes"] as? String)))
        XCTAssertEqual(bytes, Data("\u{1B}[200~\(text)\u{1B}[201~".utf8))
    }

    func testCloseUnlinksTheFIFOAndSendBecomesANoOp() {
        guard let channel = PaneControlChannel() else {
            XCTFail("expected a FIFO to be created")
            return
        }
        let path = channel.path
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))

        channel.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))

        // Must not crash or reopen the unlinked path.
        channel.send(["type": "terminal.input", "bytes": "aGk="])
    }

    func testInitReturnsNilWhenDirectoryDoesNotExist() {
        let missing = URL(fileURLWithPath: "/private/tmp/flock-tests-missing-\(UUID().uuidString)")
        XCTAssertNil(PaneControlChannel(directory: missing))
    }
}

/// Accumulates FIFO reads on a draining thread until the first newline ends a
/// line, which the test thread then reads back once its write has returned.
private final class FIFOLineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    /// Whether a complete line has now arrived.
    func append(_ data: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(data)
        return buffer.contains(0x0A)
    }

    func line() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard let newline = buffer.firstIndex(of: 0x0A) else { return nil }
        return Data(buffer[buffer.startIndex..<newline])
    }
}

private struct FIFOTimeoutError: Error {}

private func waitForNonEmptyReadFromFIFO(_ fd: Int32, timeout: Duration = .seconds(5)) throws -> Data {
    let deadline = ContinuousClock.now + timeout
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = read(fd, &buffer, buffer.count)
        if n > 0 { return Data(buffer.prefix(n)) }
        if ContinuousClock.now >= deadline { throw FIFOTimeoutError() }
        usleep(20_000)
    }
}
