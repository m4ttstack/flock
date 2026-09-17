import XCTest
@testable import FlockCore
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

final class PaneStatusChannelTests: XCTestCase {
    func testBridgeWriteReachesTheAppCallback() throws {
        let channel = try XCTUnwrap(PaneStatusChannel())
        defer { channel.close() }

        let received = LockedBox<[(Bool, Bool)]>([])
        channel.start(queue: .global(qos: .userInteractive)) { enabled, sgrPixels in
            received.mutate { $0.append((enabled, sgrPixels)) }
        }

        // Stand in for the bridge's own write end: open the FIFO path and
        // write a `flock.mouse_capture` line, exactly as `ControlBridge`
        // does through `encodeMouseCaptureStatus`.
        let writerFD = open(channel.path, O_WRONLY | O_NONBLOCK)
        XCTAssertGreaterThanOrEqual(writerFD, 0)
        defer { close(writerFD) }
        let line = try XCTUnwrap(ControlBridge.encodeMouseCaptureStatus(
            Data(#"{"type":"terminal.mouse_capture","enabled":true,"sgr_pixels":false}"#.utf8)))
        _ = line.withUnsafeBytes { write(writerFD, $0.baseAddress, $0.count) }

        let deadline = ContinuousClock.now + .seconds(5)
        while received.value.isEmpty, ContinuousClock.now < deadline {
            usleep(20_000)
        }
        XCTAssertEqual(received.value.count, 1)
        XCTAssertEqual(received.value.first?.0, true)
        XCTAssertEqual(received.value.first?.1, false)
    }

    func testParseMouseCaptureAcceptsBothFlagsAndDefaultsSgr() {
        XCTAssertEqual(
            PaneStatusChannel.parseMouseCapture(Data(#"{"type":"flock.mouse_capture","enabled":true,"sgr_pixels":true}"#.utf8))?.0, true)
        XCTAssertEqual(
            PaneStatusChannel.parseMouseCapture(Data(#"{"type":"flock.mouse_capture","enabled":false,"sgr_pixels":true}"#.utf8))?.1, true)
        // sgr_pixels missing defaults to false.
        let parsed = PaneStatusChannel.parseMouseCapture(Data(#"{"type":"flock.mouse_capture","enabled":true}"#.utf8))
        XCTAssertEqual(parsed?.0, true)
        XCTAssertEqual(parsed?.1, false)
    }

    func testBridgeFirstFrameWriteReachesTheAppCallback() throws {
        let channel = try XCTUnwrap(PaneStatusChannel())
        defer { channel.close() }

        let received = LockedBox<Int>(0)
        channel.start(
            queue: .global(qos: .userInteractive),
            onFirstFrame: { received.mutate { $0 += 1 } }
        ) { _, _ in }

        let writerFD = open(channel.path, O_WRONLY | O_NONBLOCK)
        XCTAssertGreaterThanOrEqual(writerFD, 0)
        defer { close(writerFD) }
        let line = try XCTUnwrap(ControlBridge.encodeLine(["type": "flock.first_frame"]))
        _ = line.withUnsafeBytes { write(writerFD, $0.baseAddress, $0.count) }

        let deadline = ContinuousClock.now + .seconds(5)
        while received.value == 0, ContinuousClock.now < deadline {
            usleep(20_000)
        }
        XCTAssertEqual(received.value, 1)
    }

    func testParseFirstFrameAcceptsExactTypeAndRejectsOthers() {
        XCTAssertTrue(PaneStatusChannel.parseFirstFrame(Data(#"{"type":"flock.first_frame"}"#.utf8)))
        XCTAssertFalse(PaneStatusChannel.parseFirstFrame(Data(#"{"type":"flock.mouse_capture","enabled":true}"#.utf8)))
        XCTAssertFalse(PaneStatusChannel.parseFirstFrame(Data("{not json".utf8)))
    }

    func testParseMouseCaptureRejectsOtherLines() {
        XCTAssertNil(PaneStatusChannel.parseMouseCapture(Data(#"{"type":"terminal.frame","bytes":"AA=="}"#.utf8)))
        XCTAssertNil(PaneStatusChannel.parseMouseCapture(Data(#"{"type":"flock.mouse_capture"}"#.utf8)))
        XCTAssertNil(PaneStatusChannel.parseMouseCapture(Data("{not json".utf8)))
    }

    func testCloseUnlinksTheFIFO() {
        guard let channel = PaneStatusChannel() else {
            XCTFail("expected a FIFO to be created")
            return
        }
        let path = channel.path
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        channel.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    /// After `start`, closing goes through the source's cancel handler; a
    /// second close and a late write must both be harmless.
    func testCloseAfterStartIsSafeAndIdempotent() throws {
        let channel = try XCTUnwrap(PaneStatusChannel())
        channel.start(queue: .global(qos: .userInteractive)) { _, _ in }
        let path = channel.path
        channel.close()
        channel.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testInitReturnsNilWhenDirectoryDoesNotExist() {
        let missing = URL(fileURLWithPath: "/private/tmp/flock-tests-missing-\(UUID().uuidString)")
        XCTAssertNil(PaneStatusChannel(directory: missing))
    }
}

private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ initial: T) { stored = initial }
    var value: T { lock.lock(); defer { lock.unlock() }; return stored }
    func mutate(_ body: (inout T) -> Void) { lock.lock(); defer { lock.unlock() }; body(&stored) }
}
