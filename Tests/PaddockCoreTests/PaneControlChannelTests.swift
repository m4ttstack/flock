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

        channel.send(["type": "terminal.resize", "cols": 100, "rows": 40])

        let line = try waitForNonEmptyReadFromFIFO(readerFD)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: line.split(separator: 0x0A)[0]) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "terminal.resize")
        XCTAssertEqual(object["cols"] as? Int, 100)
        XCTAssertEqual(object["rows"] as? Int, 40)
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
        channel.send(["type": "terminal.resize", "cols": 80, "rows": 24])
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
