import XCTest
@testable import PaddockCore
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
        let missing = URL(fileURLWithPath: "/private/tmp/paddock-tests-missing-\(UUID().uuidString)")
        XCTAssertNil(PaneControlChannel(directory: missing))
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
