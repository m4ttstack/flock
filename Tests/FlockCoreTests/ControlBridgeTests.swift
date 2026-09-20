import XCTest
@testable import FlockCore
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

private struct BridgeTimeoutError: Error {}

/// Never touches `ControlBridge.run()` directly: it calls `exit()` on every
/// path, which would kill the test process. Everything here targets the
/// pieces `run()` is built from -- `BridgeOptions`, the pure NDJSON
/// encode/decode/filter functions, `BridgeChildOwner`, and `BridgeIO` wired
/// to plain anonymous pipes standing in for the PTY and for herdr's own
/// pipes -- so the real process-spawning integration is left to the manual
/// smoke test (brief Step 5), and everything that can be exercised without a
/// real herdr child is exercised here.
final class ControlBridgeTests: XCTestCase {
    // MARK: - BridgeOptions

    func testBridgeOptionsParsesAllFlags() {
        let options = BridgeOptions(arguments: [
            "--bridge", "w1:p1",
            "--socket", "/tmp/a.sock",
            "--herdr-bin", "/opt/homebrew/bin/herdr",
            "--control-pipe", "/tmp/ctl.fifo",
            "--status-pipe", "/tmp/status.fifo",
        ], environment: [:])
        XCTAssertEqual(options.target, "w1:p1")
        XCTAssertEqual(options.socketPath, "/tmp/a.sock")
        XCTAssertEqual(options.herdrBinary, "/opt/homebrew/bin/herdr")
        XCTAssertEqual(options.controlPipe, "/tmp/ctl.fifo")
        XCTAssertEqual(options.statusPipe, "/tmp/status.fifo")
    }

    func testBridgeOptionsFallsBackToEnvironmentWhenFlagsAbsent() {
        let options = BridgeOptions(arguments: [], environment: [
            "HERDR_TERM_TARGET": "w2:p3",
            "HERDR_SOCKET_PATH": "/tmp/env.sock",
            "HERDR_BIN": "/usr/local/bin/herdr",
            PaneControlChannel.environmentKey: "/tmp/env-ctl.fifo",
            PaneStatusChannel.environmentKey: "/tmp/env-status.fifo",
        ])
        XCTAssertEqual(options.target, "w2:p3")
        XCTAssertEqual(options.socketPath, "/tmp/env.sock")
        XCTAssertEqual(options.herdrBinary, "/usr/local/bin/herdr")
        XCTAssertEqual(options.controlPipe, "/tmp/env-ctl.fifo")
        XCTAssertEqual(options.statusPipe, "/tmp/env-status.fifo")
    }

    func testBridgeOptionsFlagWinsOverEnvironment() {
        let options = BridgeOptions(
            arguments: ["--bridge", "flag-target"],
            environment: ["HERDR_TERM_TARGET": "env-target"]
        )
        XCTAssertEqual(options.target, "flag-target")
    }

    func testBridgeOptionsMissingTargetIsEmpty() {
        let options = BridgeOptions(arguments: ["--socket", "/tmp/a.sock"], environment: [:])
        XCTAssertEqual(options.target, "")
    }

    func testArgvRoundTripsThroughBridgeOptions() {
        let argv = BridgeOptions.argv(
            executablePath: "/Applications/Flock.app/Contents/MacOS/Flock",
            target: "w3:p2",
            socketPath: "/tmp/round.sock",
            herdrBinary: "/opt/homebrew/bin/herdr",
            controlPipe: "/tmp/round-ctl.fifo",
            statusPipe: "/tmp/round-status.fifo"
        )
        // First element is the executable path, not a flag; BridgeOptions
        // only ever parses arguments AFTER argv[0].
        let options = BridgeOptions(arguments: Array(argv.dropFirst()), environment: [:])
        XCTAssertEqual(options.target, "w3:p2")
        XCTAssertEqual(options.socketPath, "/tmp/round.sock")
        XCTAssertEqual(options.herdrBinary, "/opt/homebrew/bin/herdr")
        XCTAssertEqual(options.controlPipe, "/tmp/round-ctl.fifo")
        XCTAssertEqual(options.statusPipe, "/tmp/round-status.fifo")
    }

    // MARK: - startup clear screen (login-banner flash)

    func testStartupClearScreenIsClearPlusHome() {
        XCTAssertEqual(ControlBridge.startupClearScreen, Data("\u{1B}[2J\u{1B}[H".utf8))
    }

    func testWriteStartupClearScreenWritesToGivenFD() {
        let pipe = Pipe()
        ControlBridge.writeStartupClearScreen(to: pipe.fileHandleForWriting.fileDescriptor)
        let written = readAllAvailableForTest(pipe.fileHandleForReading.fileDescriptor)
        XCTAssertEqual(written, ControlBridge.startupClearScreen)
    }

    // MARK: - PTYResizeRelay (the PTY's size is the only size herdr hears)

    func testRelaySendsEachNewWinsize() {
        var relay = PTYResizeRelay(spawned: PTYSize(cols: 30, rows: 40))
        XCTAssertEqual(relay.pending(PTYSize(cols: 60, rows: 41)), PTYSize(cols: 60, rows: 41))
        relay.delivered(PTYSize(cols: 60, rows: 41))
        XCTAssertEqual(relay.pending(PTYSize(cols: 30, rows: 40)), PTYSize(cols: 30, rows: 40), "back to the spawn size is a change too")
    }

    func testRelayDropsAnUnchangedOrUnreadableWinsize() {
        var relay = PTYResizeRelay(spawned: PTYSize(cols: 30, rows: 40))
        XCTAssertNil(relay.pending(PTYSize(cols: 30, rows: 40)), "herdr was spawned at this size")
        XCTAssertEqual(relay.pending(PTYSize(cols: 60, rows: 41)), PTYSize(cols: 60, rows: 41))
        relay.delivered(PTYSize(cols: 60, rows: 41))
        XCTAssertNil(relay.pending(PTYSize(cols: 60, rows: 41)), "herdr already has this size")
        XCTAssertNil(relay.pending(nil))
        XCTAssertNil(relay.pending(PTYSize(cols: 0, rows: 41)))
        XCTAssertNil(relay.pending(PTYSize(cols: 60, rows: 0)))
        XCTAssertEqual(relay.herdrSize, PTYSize(cols: 60, rows: 41), "an unreadable size forgets nothing")
    }

    /// Asking is not recording. A size the bridge could not write -- the
    /// descriptor is parked at -1 for as long as flock's hold is released --
    /// is still owed to herdr, and the relay has to keep owing it: nothing
    /// re-reads a winsize that has not changed since, so a relay that recorded
    /// on the attempt would drop that resize for the pane's whole life.
    func testAWinsizeThatCouldNotBeWrittenIsStillOwed() {
        var relay = PTYResizeRelay(spawned: PTYSize(cols: 30, rows: 40))
        let grown = PTYSize(cols: 133, rows: 46)

        XCTAssertEqual(relay.pending(grown), grown)
        // The write failed, so nothing is recorded.
        XCTAssertEqual(relay.pending(grown), grown, "an undelivered size is still owed")
        XCTAssertEqual(relay.herdrSize, PTYSize(cols: 30, rows: 40))

        relay.delivered(grown)
        XCTAssertNil(relay.pending(grown))
    }

    // MARK: - childArgv (one control child, for the bridge's whole life)

    func testChildArgvIsAlwaysAControlTakeoverAtTheGivenDims() {
        let argv = ControlBridge.childArgv(target: "w1:p1", cols: 120, rows: 40)
        XCTAssertEqual(
            argv, ["terminal", "session", "control", "w1:p1", "--takeover", "--cols", "120", "--rows", "40"])
        XCTAssertFalse(argv.contains("observe"), "no observe path remains: every pane is attached")
    }

    // MARK: - parseFrame / encodeInput / parseForwardableControlCommand

    func testParseFrameValid() {
        let line = ControlBridge.encodeLine(["type": "terminal.frame", "bytes": Data("hello".utf8).base64EncodedString()])!
        XCTAssertEqual(ControlBridge.parseFrame(line.dropLast())?.bytes, Data("hello".utf8))
    }

    func testParseFrameRejectsWrongType() {
        let line = ControlBridge.encodeLine(["type": "terminal.closed"])!
        XCTAssertNil(ControlBridge.parseFrame(line.dropLast()))
    }

    func testParseFrameRejectsMalformedJSON() {
        XCTAssertNil(ControlBridge.parseFrame(Data("not json at all".utf8)))
    }

    func testParseFrameRejectsEmptyDecodedBytes() {
        let line = ControlBridge.encodeLine(["type": "terminal.frame", "bytes": ""])!
        XCTAssertNil(ControlBridge.parseFrame(line.dropLast()))
    }

    func testParseFrameReadsTheFullFlag() {
        let line = ControlBridge.encodeLine(["type": "terminal.frame", "bytes": "aGk=", "full": true])!
        XCTAssertEqual(ControlBridge.parseFrame(line.dropLast())?.full, true)
    }

    func testParseFrameWithoutAFullFieldIsIncremental() {
        let line = ControlBridge.encodeLine(["type": "terminal.frame", "bytes": "aGk="])!
        XCTAssertEqual(ControlBridge.parseFrame(line.dropLast())?.full, false)
    }

    func testEncodeInputBase64RoundTrips() {
        let original = Data([0x00, 0x1B, 0x5B, 0x41, 0xFF])
        let object = ControlBridge.encodeInput(original)
        XCTAssertEqual(object["type"] as? String, "terminal.input")
        let decoded = (object["bytes"] as? String).flatMap { Data(base64Encoded: $0) }
        XCTAssertEqual(decoded, original)
    }

    func testParseForwardableControlCommandAcceptsPlainInput() {
        let line = ControlBridge.encodeLine(["type": "terminal.input", "bytes": "aGk="])!
        let parsed = ControlBridge.parseForwardableControlCommand(line.dropLast())
        XCTAssertEqual(parsed?["type"] as? String, "terminal.input")
    }

    /// Scroll forwards to herdr like every other `terminal.*` command: it
    /// moves the pane's real, shared viewport (see `PaneControlChannel.scroll`).
    func testParseForwardableControlCommandAcceptsScroll() {
        let line = ControlBridge.encodeLine([
            "type": "terminal.scroll", "direction": "up", "lines": 5, "source": "wheel",
        ])!
        let parsed = ControlBridge.parseForwardableControlCommand(line.dropLast())
        XCTAssertEqual(parsed?["type"] as? String, "terminal.scroll")
        XCTAssertEqual(parsed?["direction"] as? String, "up")
        XCTAssertEqual(parsed?["lines"] as? Int, 5)
    }

    /// Structured mouse events ride the same `terminal.*` filter that carries
    /// input and scroll.
    func testParseForwardableControlCommandAcceptsMouse() {
        let line = ControlBridge.encodeLine([
            "type": "terminal.mouse", "kind": "down", "button": "left",
            "column": 9, "row": 4, "modifiers": 0, "lines": 1,
        ])!
        let parsed = ControlBridge.parseForwardableControlCommand(line.dropLast())
        XCTAssertEqual(parsed?["type"] as? String, "terminal.mouse")
        XCTAssertEqual(parsed?["button"] as? String, "left")
    }

    func testParseForwardableControlCommandRejectsNonTerminalType() {
        let line = ControlBridge.encodeLine(["type": "session.hello"])!
        XCTAssertNil(ControlBridge.parseForwardableControlCommand(line.dropLast()))
    }

    func testParseForwardableControlCommandRejectsAResize() {
        let line = ControlBridge.encodeLine(["type": "terminal.resize", "cols": 60, "rows": 41])!
        XCTAssertNil(ControlBridge.parseForwardableControlCommand(line.dropLast()))
    }

    // MARK: - encodeMouseCaptureStatus (bridge -> app status line)

    func testEncodeMouseCaptureStatusTranslatesHerdrLine() throws {
        let line = try XCTUnwrap(ControlBridge.encodeMouseCaptureStatus(
            Data(#"{"type":"terminal.mouse_capture","enabled":true,"sgr_pixels":true}"#.utf8)))
        XCTAssertEqual(line.last, 0x0A, "status lines are newline-terminated for the app's line reader")
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: line.dropLast()) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "flock.mouse_capture")
        XCTAssertEqual(object["enabled"] as? Bool, true)
        XCTAssertEqual(object["sgr_pixels"] as? Bool, true)
    }

    func testEncodeMouseCaptureStatusDefaultsSgrPixelsAndRejectsOthers() throws {
        let defaulted = try XCTUnwrap(ControlBridge.encodeMouseCaptureStatus(
            Data(#"{"type":"terminal.mouse_capture","enabled":false}"#.utf8)))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: defaulted.dropLast()) as? [String: Any])
        XCTAssertEqual(object["enabled"] as? Bool, false)
        XCTAssertEqual(object["sgr_pixels"] as? Bool, false)
        XCTAssertNil(ControlBridge.encodeMouseCaptureStatus(Data(#"{"type":"terminal.frame","bytes":"AA=="}"#.utf8)))
        XCTAssertNil(ControlBridge.encodeMouseCaptureStatus(Data("{not json".utf8)))
    }

    func testParseForwardableControlCommandRejectsMalformedJSON() {
        XCTAssertNil(ControlBridge.parseForwardableControlCommand(Data("{not json".utf8)))
    }

    // MARK: - BridgeIO over anonymous pipes (fake control peer, no real herdr child)

    func testHerdrOutputFrameSplitAcrossHostilePointsStillDecodes() async throws {
        let fromHerdr = Pipe()
        let stdoutCapture = Pipe()
        let herdrIn = Pipe()
        let io = BridgeIO(
            herdrInFD: herdrIn.fileHandleForWriting.fileDescriptor,
            stdinFD: Pipe().fileHandleForReading.fileDescriptor,
            stdoutFD: stdoutCapture.fileHandleForWriting.fileDescriptor,
            onPeerGone: { _ in }
        )
        io.startHerdrOutput(fromHerdr.fileHandleForReading)

        let payload = Data("HELLO \u{20AC} WORLD".utf8)
        let line = ControlBridge.encodeLine(["type": "terminal.frame", "bytes": payload.base64EncodedString()])!

        // Hostile split points: right after the opening brace, mid-base64
        // payload, and one byte before the trailing newline.
        for splitIndex in [1, line.count / 2, line.count - 2] {
            let first = line.prefix(splitIndex)
            let second = line.suffix(from: splitIndex)
            fromHerdr.fileHandleForWriting.write(first)
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertEqual(
                readAllAvailableForTest(stdoutCapture.fileHandleForReading.fileDescriptor).count, 0,
                "split at byte \(splitIndex) must not decode anything before the line completes"
            )
            fromHerdr.fileHandleForWriting.write(second)
            let decoded = try await waitForNonEmptyRead(stdoutCapture.fileHandleForReading.fileDescriptor)
            XCTAssertEqual(decoded, payload, "split at byte \(splitIndex) must still decode the frame cleanly")
        }
    }

    /// A `terminal.mouse_capture` line from the herdr child is relayed to the
    /// status FIFO as `flock.mouse_capture`, never to the PTY stdout; a
    /// `terminal.frame` still goes only to stdout.
    func testHerdrOutputRelaysMouseCaptureToStatusFDAndFramesToStdout() async throws {
        let fromHerdr = Pipe()
        let stdoutCapture = Pipe()
        let statusCapture = Pipe()
        let io = BridgeIO(
            herdrInFD: Pipe().fileHandleForWriting.fileDescriptor,
            stdinFD: Pipe().fileHandleForReading.fileDescriptor,
            stdoutFD: stdoutCapture.fileHandleForWriting.fileDescriptor,
            statusFD: statusCapture.fileHandleForWriting.fileDescriptor,
            onPeerGone: { _ in }
        )
        io.startHerdrOutput(fromHerdr.fileHandleForReading)

        let captureLine = ControlBridge.encodeLine([
            "type": "terminal.mouse_capture", "enabled": true, "sgr_pixels": false,
        ])!
        fromHerdr.fileHandleForWriting.write(captureLine)

        let status = try await waitForNonEmptyRead(statusCapture.fileHandleForReading.fileDescriptor)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: status.split(separator: 0x0A)[0]) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "flock.mouse_capture")
        XCTAssertEqual(object["enabled"] as? Bool, true)
        // The capture line must not have leaked onto the PTY stdout.
        XCTAssertEqual(readAllAvailableForTest(stdoutCapture.fileHandleForReading.fileDescriptor).count, 0)

        // A real frame still reaches stdout, not the status pipe.
        let payload = Data("PAINT".utf8)
        let frame = ControlBridge.encodeLine(["type": "terminal.frame", "bytes": payload.base64EncodedString()])!
        fromHerdr.fileHandleForWriting.write(frame)
        let decoded = try await waitForNonEmptyRead(stdoutCapture.fileHandleForReading.fileDescriptor)
        XCTAssertEqual(decoded, payload)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(readAllAvailableForTest(statusCapture.fileHandleForReading.fileDescriptor).count, 0)
    }

    /// The bridge's one-shot first-frame signal: silent for an incremental
    /// frame, fires exactly once on the first FULL frame, and never again for
    /// a later full frame (herdr repaints in full on every resize, and that
    /// must not re-show a pane's status card).
    func testFirstFrameStatusLineEmittedOnceOnTheFirstFullFrameOnly() async throws {
        let fromHerdr = Pipe()
        let stdoutCapture = Pipe()
        let statusCapture = Pipe()
        let io = BridgeIO(
            herdrInFD: Pipe().fileHandleForWriting.fileDescriptor,
            stdinFD: Pipe().fileHandleForReading.fileDescriptor,
            stdoutFD: stdoutCapture.fileHandleForWriting.fileDescriptor,
            statusFD: statusCapture.fileHandleForWriting.fileDescriptor,
            onPeerGone: { _ in }
        )
        io.startHerdrOutput(fromHerdr.fileHandleForReading)

        let partial = ControlBridge.encodeLine([
            "type": "terminal.frame", "bytes": Data("partial".utf8).base64EncodedString(), "full": false,
        ])!
        fromHerdr.fileHandleForWriting.write(partial)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(
            readAllAvailableForTest(statusCapture.fileHandleForReading.fileDescriptor).count, 0,
            "an incremental frame must never emit first_frame")

        let full1 = ControlBridge.encodeLine([
            "type": "terminal.frame", "bytes": Data("full1".utf8).base64EncodedString(), "full": true,
        ])!
        fromHerdr.fileHandleForWriting.write(full1)
        let status = try await waitForNonEmptyRead(statusCapture.fileHandleForReading.fileDescriptor)
        let lines = status.split(separator: 0x0A)
        XCTAssertEqual(lines.count, 1, "exactly one status line for the first full frame")
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(lines[0])) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "flock.first_frame")

        let full2 = ControlBridge.encodeLine([
            "type": "terminal.frame", "bytes": Data("full2".utf8).base64EncodedString(), "full": true,
        ])!
        fromHerdr.fileHandleForWriting.write(full2)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(
            readAllAvailableForTest(statusCapture.fileHandleForReading.fileDescriptor).count, 0,
            "first_frame must be emitted exactly once, ever, even across a later full frame")
    }

    /// A pane with nothing painted yet shows herdr's own stderr: an attach
    /// that never succeeded has no frames to be spoiled, and the text is the
    /// only account of why the pane is empty.
    func testHerdrDiagnosticsReachThePTYWhileNoFrameHasBeenPainted() async throws {
        let herdrErr = Pipe()
        let stdoutCapture = Pipe()
        let io = BridgeIO(
            herdrInFD: Pipe().fileHandleForWriting.fileDescriptor,
            stdinFD: Pipe().fileHandleForReading.fileDescriptor,
            stdoutFD: stdoutCapture.fileHandleForWriting.fileDescriptor,
            onPeerGone: { _ in }
        )
        io.startHerdrDiagnostics(herdrErr.fileHandleForReading)

        herdrErr.fileHandleForWriting.write(Data("herdr: connection failed\n".utf8))
        let shown = try await waitForNonEmptyRead(stdoutCapture.fileHandleForReading.fileDescriptor)
        XCTAssertEqual(
            String(decoding: shown, as: UTF8.self), "herdr: connection failed\r\n",
            "the PTY is in raw mode, so the line needs its own carriage return")
    }

    /// Once a frame has been painted, the pane is a mirror of herdr's screen
    /// and nothing else may write to it. herdr answers every control command
    /// it does not recognize with a ~200 byte diagnostic, so a herdr without
    /// the mouse verbs would otherwise scribble one over the mirror per click.
    func testHerdrDiagnosticsStayOffThePTYOnceAFrameIsPainted() async throws {
        let fromHerdr = Pipe()
        let herdrErr = Pipe()
        let stdoutCapture = Pipe()
        let io = BridgeIO(
            herdrInFD: Pipe().fileHandleForWriting.fileDescriptor,
            stdinFD: Pipe().fileHandleForReading.fileDescriptor,
            stdoutFD: stdoutCapture.fileHandleForWriting.fileDescriptor,
            onPeerGone: { _ in }
        )
        io.startHerdrOutput(fromHerdr.fileHandleForReading)
        io.startHerdrDiagnostics(herdrErr.fileHandleForReading)

        let painted = Data("PAINT".utf8)
        fromHerdr.fileHandleForWriting.write(
            ControlBridge.encodeLine(["type": "terminal.frame", "bytes": painted.base64EncodedString()])!)
        let mirrored = try await waitForNonEmptyRead(stdoutCapture.fileHandleForReading.fileDescriptor)
        XCTAssertEqual(mirrored, painted)

        herdrErr.fileHandleForWriting.write(
            Data("herdr: terminal session control input ignored: invalid json command\n".utf8))
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(
            readAllAvailableForTest(stdoutCapture.fileHandleForReading.fileDescriptor).count, 0,
            "a diagnostic must never be painted over a live mirror")
    }

    func testHerdrOutputSkipsMalformedLineWithoutStoppingSubsequentFrames() async throws {
        let fromHerdr = Pipe()
        let stdoutCapture = Pipe()
        let herdrIn = Pipe()
        let io = BridgeIO(
            herdrInFD: herdrIn.fileHandleForWriting.fileDescriptor,
            stdinFD: Pipe().fileHandleForReading.fileDescriptor,
            stdoutFD: stdoutCapture.fileHandleForWriting.fileDescriptor,
            onPeerGone: { _ in }
        )
        io.startHerdrOutput(fromHerdr.fileHandleForReading)

        let payload = Data("still alive".utf8)
        let validLine = ControlBridge.encodeLine(["type": "terminal.frame", "bytes": payload.base64EncodedString()])!
        var garbage = Data("not json at all".utf8)
        garbage.append(0x0A)

        fromHerdr.fileHandleForWriting.write(garbage)
        fromHerdr.fileHandleForWriting.write(validLine)

        let decoded = try await waitForNonEmptyRead(stdoutCapture.fileHandleForReading.fileDescriptor)
        XCTAssertEqual(decoded, payload)
    }

    func testControlPipeForwardsInputAndScrollButDropsGarbage() async throws {
        let control = Pipe()
        let herdrIn = Pipe()
        let io = BridgeIO(
            herdrInFD: herdrIn.fileHandleForWriting.fileDescriptor,
            stdinFD: Pipe().fileHandleForReading.fileDescriptor,
            stdoutFD: Pipe().fileHandleForWriting.fileDescriptor,
            onPeerGone: { _ in }
        )
        io.startControlPipe(fd: control.fileHandleForReading.fileDescriptor, closeOnCancel: false)

        var garbage = Data("{not json".utf8)
        garbage.append(0x0A)
        let scrollLine = ControlBridge.encodeLine([
            "type": "terminal.scroll", "direction": "up", "lines": 5, "source": "wheel",
        ])!
        let inputLine = ControlBridge.encodeLine(["type": "terminal.input", "bytes": "aGk="])!

        control.fileHandleForWriting.write(garbage)
        control.fileHandleForWriting.write(scrollLine)
        control.fileHandleForWriting.write(inputLine)

        let forwarded = try await waitForNonEmptyReadOfAtLeast(herdrIn.fileHandleForReading.fileDescriptor, lines: 2)
        let lines = forwarded.split(separator: 0x0A)
        XCTAssertEqual(lines.count, 2, "the scroll and input commands both forward; only the malformed line is dropped")
        let scrollObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(lines[0])) as? [String: Any])
        XCTAssertEqual(scrollObject["type"] as? String, "terminal.scroll")
        let inputObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(lines[1])) as? [String: Any])
        XCTAssertEqual(inputObject["type"] as? String, "terminal.input")
    }

    func testStdinEncodesToTerminalInputThenReleaseOnEOF() async throws {
        let stdinStandIn = Pipe()
        let herdrIn = Pipe()
        let io = BridgeIO(
            herdrInFD: herdrIn.fileHandleForWriting.fileDescriptor,
            stdinFD: stdinStandIn.fileHandleForReading.fileDescriptor,
            stdoutFD: Pipe().fileHandleForWriting.fileDescriptor,
            onPeerGone: { _ in }
        )
        io.startStdin()

        let typed = Data("echo hi\r".utf8)
        stdinStandIn.fileHandleForWriting.write(typed)
        let firstLine = try await waitForNonEmptyRead(herdrIn.fileHandleForReading.fileDescriptor)
        let inputObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: firstLine.split(separator: 0x0A)[0]) as? [String: Any])
        XCTAssertEqual(inputObject["type"] as? String, "terminal.input")
        XCTAssertEqual((inputObject["bytes"] as? String).flatMap { Data(base64Encoded: $0) }, typed)

        try stdinStandIn.fileHandleForWriting.close()
        let releaseLine = try await waitForNonEmptyRead(herdrIn.fileHandleForReading.fileDescriptor)
        let releaseObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: releaseLine.split(separator: 0x0A)[0]) as? [String: Any])
        XCTAssertEqual(releaseObject["type"] as? String, "terminal.release")
    }

    func testSendAfterCloseIsANoOp() {
        let herdrIn = Pipe()
        let io = BridgeIO(
            herdrInFD: herdrIn.fileHandleForWriting.fileDescriptor,
            stdinFD: Pipe().fileHandleForReading.fileDescriptor,
            stdoutFD: Pipe().fileHandleForWriting.fileDescriptor,
            onPeerGone: { _ in }
        )
        io.close()
        io.send(["type": "terminal.resize", "cols": 80, "rows": 24])
        XCTAssertEqual(readAllAvailableForTest(herdrIn.fileHandleForReading.fileDescriptor).count, 0)
    }

    // MARK: - resize: only the PTY's own size, only from SIGWINCH or the startup read

    func testSpawnSizeIsThePTYSizeWheneverThePTYReportsOne() {
        XCTAssertEqual(ControlBridge.spawnSize(ptyWinsize: PTYSize(cols: 60, rows: 41)), PTYSize(cols: 60, rows: 41))
        XCTAssertEqual(ControlBridge.spawnSize(ptyWinsize: PTYSize(cols: 0, rows: 0)), PTYSize(cols: 80, rows: 24))
        XCTAssertEqual(ControlBridge.spawnSize(ptyWinsize: PTYSize(cols: 60, rows: 0)), PTYSize(cols: 60, rows: 24))
    }

    /// No signal is raised: the read after arming is what sends it.
    func testStartingTheRelaySendsAPTYSizeThatLeftTheSpawnSize() async throws {
        let herdrIn = Pipe()
        let io = BridgeIO(
            herdrInFD: herdrIn.fileHandleForWriting.fileDescriptor,
            stdinFD: Pipe().fileHandleForReading.fileDescriptor,
            stdoutFD: Pipe().fileHandleForWriting.fileDescriptor,
            spawnedSize: PTYSize(cols: 30, rows: 40), ptySize: { PTYSize(cols: 60, rows: 41) },
            onPeerGone: { _ in }
        )
        defer { io.close() }

        io.startPTYSizeRelay()

        try await Task.sleep(for: .milliseconds(100))
        let lines = readAllAvailableForTest(herdrIn.fileHandleForReading.fileDescriptor).split(separator: 0x0A)
        XCTAssertEqual(lines.count, 1)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(lines.first))) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "terminal.resize")
        XCTAssertEqual(object["cols"] as? Int, 60)
        XCTAssertEqual(object["rows"] as? Int, 41)
    }

    func testStartingTheRelayAtTheSpawnSizeSendsNothing() async throws {
        let herdrIn = Pipe()
        let io = BridgeIO(
            herdrInFD: herdrIn.fileHandleForWriting.fileDescriptor,
            stdinFD: Pipe().fileHandleForReading.fileDescriptor,
            stdoutFD: Pipe().fileHandleForWriting.fileDescriptor,
            spawnedSize: PTYSize(cols: 30, rows: 40), ptySize: { PTYSize(cols: 30, rows: 40) },
            onPeerGone: { _ in }
        )
        defer { io.close() }

        io.startPTYSizeRelay()

        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(readAllAvailableForTest(herdrIn.fileHandleForReading.fileDescriptor).count, 0)
    }

    func testSIGWINCHSendsThePTYWinsize() async throws {
        let herdrIn = Pipe()
        let winsize = LockedBox(PTYSize(cols: 30, rows: 40))
        let io = BridgeIO(
            herdrInFD: herdrIn.fileHandleForWriting.fileDescriptor,
            stdinFD: Pipe().fileHandleForReading.fileDescriptor,
            stdoutFD: Pipe().fileHandleForWriting.fileDescriptor,
            spawnedSize: PTYSize(cols: 30, rows: 40), ptySize: { winsize.value },
            onPeerGone: { _ in }
        )
        defer { io.close() }
        io.startPTYSizeRelay()

        winsize.mutate { $0 = PTYSize(cols: 60, rows: 41) }
        kill(getpid(), SIGWINCH)

        let lines = try await waitForNonEmptyRead(herdrIn.fileHandleForReading.fileDescriptor).split(separator: 0x0A)
        XCTAssertEqual(lines.count, 1)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(lines.first))) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "terminal.resize")
        XCTAssertEqual(object["cols"] as? Int, 60)
        XCTAssertEqual(object["rows"] as? Int, 41)
    }

    func testSIGWINCHWithAnUnchangedWinsizeSendsNothing() async throws {
        let herdrIn = Pipe()
        let winsize = LockedBox(PTYSize(cols: 30, rows: 40))
        let io = BridgeIO(
            herdrInFD: herdrIn.fileHandleForWriting.fileDescriptor,
            stdinFD: Pipe().fileHandleForReading.fileDescriptor,
            stdoutFD: Pipe().fileHandleForWriting.fileDescriptor,
            spawnedSize: PTYSize(cols: 30, rows: 40), ptySize: { winsize.value },
            onPeerGone: { _ in }
        )
        defer { io.close() }
        io.startPTYSizeRelay()

        kill(getpid(), SIGWINCH)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(
            readAllAvailableForTest(herdrIn.fileHandleForReading.fileDescriptor).count, 0,
            "herdr was spawned at the PTY's size")

        winsize.mutate { $0 = PTYSize(cols: 60, rows: 41) }
        kill(getpid(), SIGWINCH)
        let sent = try await waitForNonEmptyRead(herdrIn.fileHandleForReading.fileDescriptor)
        XCTAssertEqual(sent.split(separator: 0x0A).count, 1)

        kill(getpid(), SIGWINCH)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(
            readAllAvailableForTest(herdrIn.fileHandleForReading.fileDescriptor).count, 0,
            "a repeat of the size herdr already has sends nothing")
    }

    /// A size on the control FIFO never reaches herdr, whether as
    /// `terminal.resize` or as a `flock.dims` line; input still does.
    func testTheControlPipeCarriesNoSizeToHerdr() async throws {
        let control = Pipe()
        let herdrIn = Pipe()
        let io = BridgeIO(
            herdrInFD: herdrIn.fileHandleForWriting.fileDescriptor,
            stdinFD: Pipe().fileHandleForReading.fileDescriptor,
            stdoutFD: Pipe().fileHandleForWriting.fileDescriptor,
            spawnedSize: PTYSize(cols: 30, rows: 40), ptySize: { PTYSize(cols: 30, rows: 40) },
            onPeerGone: { _ in }
        )
        io.startControlPipe(fd: control.fileHandleForReading.fileDescriptor, closeOnCancel: false)

        control.fileHandleForWriting.write(ControlBridge.encodeLine(["type": "terminal.resize", "cols": 60, "rows": 41])!)
        control.fileHandleForWriting.write(ControlBridge.encodeLine(["type": "flock.dims", "cols": 60, "rows": 41])!)
        control.fileHandleForWriting.write(ControlBridge.encodeLine(["type": "terminal.input", "bytes": "aGk="])!)

        let forwarded = try await waitForNonEmptyRead(herdrIn.fileHandleForReading.fileDescriptor)
        try await Task.sleep(for: .milliseconds(80))
        let lines = (forwarded + readAllAvailableForTest(herdrIn.fileHandleForReading.fileDescriptor)).split(separator: 0x0A)
        XCTAssertEqual(lines.count, 1, "only the input line reaches herdr")
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(lines.first))) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "terminal.input")
    }

    // MARK: - the size sync on the control FIFO

    /// herdr resizes no pane flock holds, so the only path from a box that
    /// grew (a zoom, a divider drag, a window resize) to the pane's real grid
    /// is the PTY's own size. This is that path without a SIGWINCH: the app
    /// says the surface took a new grid, and the bridge sends what the PTY has.
    func testASizeSyncRelaysThePTYWinsizeWithNoSignal() async throws {
        let control = Pipe()
        let herdrIn = Pipe()
        let winsize = LockedBox(PTYSize(cols: 30, rows: 40))
        let io = BridgeIO(
            herdrInFD: herdrIn.fileHandleForWriting.fileDescriptor,
            stdinFD: Pipe().fileHandleForReading.fileDescriptor,
            stdoutFD: Pipe().fileHandleForWriting.fileDescriptor,
            spawnedSize: PTYSize(cols: 30, rows: 40), ptySize: { winsize.value },
            onPeerGone: { _ in }
        )
        defer { io.close() }
        io.startControlPipe(fd: control.fileHandleForReading.fileDescriptor, closeOnCancel: false)

        winsize.mutate { $0 = PTYSize(cols: 130, rows: 40) }
        control.fileHandleForWriting.write(ControlBridge.encodeLine(["type": ControlBridge.sizeSyncCommandType])!)

        let lines = try await waitForNonEmptyRead(herdrIn.fileHandleForReading.fileDescriptor).split(separator: 0x0A)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(lines.first))) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "terminal.resize")
        XCTAssertEqual(object["cols"] as? Int, 130)
        XCTAssertEqual(object["rows"] as? Int, 40)
    }

    /// The app can see the surface take a new grid before the PTY has been
    /// given it: libghostty hands the resize to its IO thread and returns. A
    /// nudge that read the winsize once, at the instant it arrived, would find
    /// the old size and send nothing, and with no SIGWINCH behind it the pane
    /// would keep its old grid for good.
    func testASizeSyncStillRelaysAWinsizeThatLandsAfterIt() async throws {
        let control = Pipe()
        let herdrIn = Pipe()
        let winsize = LockedBox(PTYSize(cols: 30, rows: 40))
        let io = BridgeIO(
            herdrInFD: herdrIn.fileHandleForWriting.fileDescriptor,
            stdinFD: Pipe().fileHandleForReading.fileDescriptor,
            stdoutFD: Pipe().fileHandleForWriting.fileDescriptor,
            spawnedSize: PTYSize(cols: 30, rows: 40), ptySize: { winsize.value },
            onPeerGone: { _ in }
        )
        defer { io.close() }
        io.startControlPipe(fd: control.fileHandleForReading.fileDescriptor, closeOnCancel: false)

        control.fileHandleForWriting.write(ControlBridge.encodeLine(["type": ControlBridge.sizeSyncCommandType])!)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(
            readAllAvailableForTest(herdrIn.fileHandleForReading.fileDescriptor).count, 0,
            "the PTY still had the size herdr was given at spawn"
        )

        winsize.mutate { $0 = PTYSize(cols: 130, rows: 40) }

        let lines = try await waitForNonEmptyRead(herdrIn.fileHandleForReading.fileDescriptor).split(separator: 0x0A)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(lines.first))) as? [String: Any])
        XCTAssertEqual(object["cols"] as? Int, 130)
    }

    /// End to end through `BridgeIO`, over a descriptor that cannot be written
    /// (what a released hold leaves behind): the resize is not lost. Once the
    /// hold is back and a live descriptor is swapped in, the same nudge at the
    /// same unchanged winsize delivers it.
    func testASizeOwedWhileTheHoldWasReleasedIsSentOnceThereIsAClientAgain() async throws {
        let control = Pipe()
        let herdrIn = Pipe()
        // -1 is exactly what a released hold leaves behind
        // (`swapHerdrInput(to: nil)`): every write fails immediately.
        let io = BridgeIO(
            herdrInFD: -1,
            stdinFD: Pipe().fileHandleForReading.fileDescriptor,
            stdoutFD: Pipe().fileHandleForWriting.fileDescriptor,
            spawnedSize: PTYSize(cols: 80, rows: 46), ptySize: { PTYSize(cols: 133, rows: 46) },
            onPeerGone: { _ in }
        )
        defer { io.close() }
        io.startControlPipe(fd: control.fileHandleForReading.fileDescriptor, closeOnCancel: false)

        let nudge = try XCTUnwrap(ControlBridge.encodeLine(["type": ControlBridge.sizeSyncCommandType]))
        control.fileHandleForWriting.write(nudge)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(
            readAllAvailableForTest(herdrIn.fileHandleForReading.fileDescriptor).count, 0,
            "this case reads a bridge whose writes go nowhere"
        )

        io.swapHerdrInput(to: herdrIn.fileHandleForWriting)
        control.fileHandleForWriting.write(nudge)

        let lines = try await waitForNonEmptyRead(herdrIn.fileHandleForReading.fileDescriptor).split(separator: 0x0A)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(lines.first))) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "terminal.resize")
        XCTAssertEqual(object["cols"] as? Int, 133)
        XCTAssertEqual(object["rows"] as? Int, 46)
    }

    /// The nudge is the bridge's own command, not a forwardable one, and it
    /// still sends nothing when the PTY is at the size herdr already has.
    func testASizeSyncIsNeverForwardedAndRepeatsSendNothing() async throws {
        let control = Pipe()
        let herdrIn = Pipe()
        let io = BridgeIO(
            herdrInFD: herdrIn.fileHandleForWriting.fileDescriptor,
            stdinFD: Pipe().fileHandleForReading.fileDescriptor,
            stdoutFD: Pipe().fileHandleForWriting.fileDescriptor,
            spawnedSize: PTYSize(cols: 30, rows: 40), ptySize: { PTYSize(cols: 30, rows: 40) },
            onPeerGone: { _ in }
        )
        defer { io.close() }
        io.startControlPipe(fd: control.fileHandleForReading.fileDescriptor, closeOnCancel: false)

        let line = try XCTUnwrap(ControlBridge.encodeLine(["type": ControlBridge.sizeSyncCommandType]))
        XCTAssertNil(ControlBridge.parseForwardableControlCommand(line))
        XCTAssertNil(ControlBridge.parseHoldCommand(line))
        control.fileHandleForWriting.write(line)
        control.fileHandleForWriting.write(line)

        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(
            readAllAvailableForTest(herdrIn.fileHandleForReading.fileDescriptor).count, 0,
            "a nudge at a size herdr already has must reach herdr as nothing at all"
        )
    }

    // MARK: - the hold commands on the control FIFO

    /// The two hold commands are read by the bridge and acted on there. They
    /// are never forwarded, and the ordinary control traffic around them still
    /// is.
    func testTheControlPipeRoutesHoldCommandsAndForwardsNeitherOfThem() async throws {
        let control = Pipe()
        let herdrIn = Pipe()
        let held = LockedBox([HoldCommand]())
        let io = BridgeIO(
            herdrInFD: herdrIn.fileHandleForWriting.fileDescriptor,
            stdinFD: Pipe().fileHandleForReading.fileDescriptor,
            stdoutFD: Pipe().fileHandleForWriting.fileDescriptor,
            spawnedSize: PTYSize(cols: 30, rows: 40), ptySize: { PTYSize(cols: 30, rows: 40) },
            onHold: { command in held.mutate { $0.append(command) } },
            onPeerGone: { _ in }
        )
        defer { io.close() }
        io.startControlPipe(fd: control.fileHandleForReading.fileDescriptor, closeOnCancel: false)

        control.fileHandleForWriting.write(ControlBridge.encodeLine(HoldCommand.release.json)!)
        control.fileHandleForWriting.write(ControlBridge.encodeLine(HoldCommand.take.json)!)
        control.fileHandleForWriting.write(ControlBridge.encodeLine(["type": "terminal.input", "bytes": "aGk="])!)

        let forwarded = try await waitForNonEmptyRead(herdrIn.fileHandleForReading.fileDescriptor)
        try await Task.sleep(for: .milliseconds(80))
        let lines = (forwarded + readAllAvailableForTest(herdrIn.fileHandleForReading.fileDescriptor))
            .split(separator: 0x0A)
        XCTAssertEqual(lines.count, 1, "a hold command was sent on to herdr")
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(lines.first))) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "terminal.input")
        XCTAssertEqual(held.value, [.release, .take])
    }

    /// A swapped-away descriptor must be closed THROUGH its handle, because
    /// the handle is what owns it: a `Pipe`'s `FileHandle` closes its own
    /// descriptor on dealloc, so freeing the number by hand leaves that dealloc
    /// to close whatever has reclaimed the number by then. Driven the
    /// deterministic way round: the number is claimed here, on purpose, before
    /// the pipe is allowed to go away.
    func testSwappingAwayAnInputDoesNotLeaveItsPipeToCloseTheNumberAgain() throws {
        var pipeBox: Pipe? = Pipe()
        // Both boxes: the `FileHandle`, not the `Pipe`, is what closes the
        // descriptor on dealloc, so a test holding the handle would keep the
        // very deinit this is about from ever running.
        var handleBox: FileHandle? = try XCTUnwrap(pipeBox).fileHandleForWriting
        let number = try XCTUnwrap(handleBox).fileDescriptor
        XCTAssertGreaterThanOrEqual(number, 0)
        let io = BridgeIO(
            herdrInFD: -1,
            stdinFD: Pipe().fileHandleForReading.fileDescriptor,
            stdoutFD: Pipe().fileHandleForWriting.fileDescriptor,
            onPeerGone: { _ in }
        )
        defer { io.close() }

        io.swapHerdrInput(to: try XCTUnwrap(handleBox))
        XCTAssertEqual(io.herdrInputDescriptor, number)
        io.swapHerdrInput(to: nil)
        XCTAssertEqual(io.herdrInputDescriptor, -1, "the writes were not parked")

        // Stand in for the next child's `pipe()`: take the freed number, on
        // purpose rather than by luck, so what happens to it next is visible.
        let spare = open("/dev/null", O_RDONLY)
        XCTAssertGreaterThanOrEqual(spare, 0)
        defer { close(spare) }
        XCTAssertEqual(dup2(spare, number), number, "the swap never freed the number at all")

        handleBox = nil
        pipeBox = nil
        XCTAssertNotEqual(
            fcntl(number, F_GETFD), -1,
            "the released pipe closed a descriptor that no longer belonged to it"
        )
        close(number)
    }

    /// What a retake rewires: herdr-bound writes follow the new child, and the
    /// relay is reseeded to the size that child was spawned at, so an
    /// unchanged PTY sends it nothing and a changed one sends it the change.
    func testSwappingTheHerdrInputMovesTheWritesAndTheRearmedRelayToTheNewChild() async throws {
        let first = Pipe()
        let second = Pipe()
        let winsize = LockedBox(PTYSize(cols: 30, rows: 40))
        let io = BridgeIO(
            herdrInFD: first.fileHandleForWriting.fileDescriptor,
            stdinFD: Pipe().fileHandleForReading.fileDescriptor,
            stdoutFD: Pipe().fileHandleForWriting.fileDescriptor,
            spawnedSize: PTYSize(cols: 30, rows: 40), ptySize: { winsize.value },
            onPeerGone: { _ in }
        )
        defer { io.close() }

        io.swapHerdrInput(to: second.fileHandleForWriting)
        io.rearmSpawnSize(PTYSize(cols: 30, rows: 40))
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(
            readAllAvailableForTest(second.fileHandleForReading.fileDescriptor).count, 0,
            "the new child was spawned at the PTY's size and told it again")

        winsize.mutate { $0 = PTYSize(cols: 61, rows: 42) }
        io.send(["type": "terminal.input", "bytes": "aGk="])
        kill(getpid(), SIGWINCH)
        io.startPTYSizeRelay()

        let sent = try await waitForNonEmptyReadOfAtLeast(second.fileHandleForReading.fileDescriptor, lines: 2)
        let types = sent.split(separator: 0x0A).compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])??["type"] as? String
        }
        XCTAssertEqual(types, ["terminal.input", "terminal.resize"])
    }

    // MARK: - BridgeChildOwner (one child, terminated once)

    /// The child outlives the assertion window by seconds, so a `terminate()`
    /// that did nothing would still be running when this checks -- the test
    /// measures the kill, not elapsed time.
    func testTerminateEndsTheChildAndIsIdempotent() {
        let proc = spawnTestChild(script: "sleep 30")
        guard proc.isRunning else { return XCTFail("failed to spawn the test child") }
        defer { if proc.isRunning { kill(proc.processIdentifier, SIGKILL) } }
        let owner = BridgeChildOwner(process: proc)

        owner.terminate()
        owner.terminate()

        XCTAssertFalse(
            waitForExit(proc, timeout: 2), "the child must be gone well before its own 30s lifetime")
    }

    /// The peer-gone path has to reap a child that ignores SIGTERM: leaving
    /// one alive parks `ControlBridge.run` in `waitUntilExit()` forever,
    /// holding the pane's attach owner and its resize lock. `/bin/sh` stands
    /// in for the wedged child. It sleeps in short steps rather than one long
    /// one for two reasons: it never reaches an exit of its own, so no wait
    /// below can pass on a child that simply ended, and SIGKILL reaches only
    /// the shell, so the `sleep` it leaves orphaned is gone in a fraction of a
    /// second rather than lingering for the rest of the run.
    func testTerminateEscalatesToSIGKILLForAChildThatIgnoresSIGTERM() {
        let output = Pipe()
        let proc = spawnTestChild(
            script: "trap '' TERM; echo trapped; while :; do sleep 0.2; done",
            standardOutput: output
        )
        guard proc.isRunning else { return XCTFail("failed to spawn the test child") }
        defer { if proc.isRunning { kill(proc.processIdentifier, SIGKILL) } }
        // The banner is printed AFTER the trap is installed, so it is the only
        // proof the child is in the state this test needs. A SIGTERM sent
        // before that kills the child on the default disposition, and the
        // escalation below would never be what ended it.
        XCTAssertTrue(
            waitForOutput("trapped", on: output.fileHandleForReading.fileDescriptor, timeout: 10),
            "the child never installed its SIGTERM trap")
        proc.terminate()
        XCTAssertTrue(
            waitForExit(proc, timeout: 0.3),
            "the child must ignore SIGTERM, or this proves nothing about the escalation")

        terminateWithBoundedEscalation(proc, timeout: 0.2)

        // Waited for, not read instantly: SIGKILL is delivered synchronously
        // but `Process.isRunning` only clears once Foundation reaps the child.
        // The wait returns the moment that happens, so the headroom here costs
        // nothing on a machine that is not loaded, and the child has no exit of
        // its own to reach inside it.
        XCTAssertFalse(
            waitForExit(proc, timeout: 10),
            "SIGTERM was ignored, so the SIGKILL fallback must have ended it")
    }

    // MARK: - startHerdrOutput: per-call buffer + generation

    /// A later `startHerdrOutput` never inherits a byte the previous handle's
    /// own line buffer was still holding: herdr flushes at 8KB chunk
    /// boundaries, so a partial (no trailing newline) line is a real state to
    /// be caught in. Gluing it onto the next handle's first line would fail to
    /// decode and lose that frame.
    func testANewHerdrOutputNeverGluesTheOldPartialLineOntoItsFirstLine() async throws {
        let stdoutCapture = Pipe()
        let oldOut = Pipe()
        let newOut = Pipe()
        let io = BridgeIO(
            herdrInFD: Pipe().fileHandleForWriting.fileDescriptor,
            stdoutFD: stdoutCapture.fileHandleForWriting.fileDescriptor, onPeerGone: { _ in })
        io.startHerdrOutput(oldOut.fileHandleForReading)

        oldOut.fileHandleForWriting.write(Data(#"{"type":"terminal.frame","#.utf8))
        try await Task.sleep(for: .milliseconds(50))

        oldOut.fileHandleForReading.readabilityHandler = nil
        io.startHerdrOutput(newOut.fileHandleForReading)

        let payload = Data("FULL REPAINT".utf8)
        let fullFrame = ControlBridge.encodeLine(["type": "terminal.frame", "bytes": payload.base64EncodedString()])!
        newOut.fileHandleForWriting.write(fullFrame)

        let decoded = try await waitForNonEmptyRead(stdoutCapture.fileHandleForReading.fileDescriptor)
        XCTAssertEqual(decoded, payload, "the new handle's own line must decode cleanly, never glued to the old partial line")
    }

    /// The harder race, driven directly: the OLD handle is left armed
    /// (standing in for an invocation of it already in flight when the
    /// generation advances) and still writes a well-formed frame afterward.
    /// That write must never reach `stdoutFD` -- the generation check inside
    /// `startHerdrOutput`'s closure is the only thing that can catch it.
    func testStaleGenerationWriteNeverReachesStdout() async throws {
        let stdoutCapture = Pipe()
        let oldOut = Pipe()
        let newOut = Pipe()
        let io = BridgeIO(
            herdrInFD: Pipe().fileHandleForWriting.fileDescriptor,
            stdoutFD: stdoutCapture.fileHandleForWriting.fileDescriptor, onPeerGone: { _ in })
        io.startHerdrOutput(oldOut.fileHandleForReading)
        io.startHerdrOutput(newOut.fileHandleForReading)

        let stalePayload = Data("STALE".utf8)
        let staleFrame = ControlBridge.encodeLine(["type": "terminal.frame", "bytes": stalePayload.base64EncodedString()])!
        oldOut.fileHandleForWriting.write(staleFrame)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(
            readAllAvailableForTest(stdoutCapture.fileHandleForReading.fileDescriptor).count, 0,
            "a write on the SUPERSEDED handle must never reach stdout once a newer generation exists")

        let freshPayload = Data("FRESH".utf8)
        let freshFrame = ControlBridge.encodeLine(["type": "terminal.frame", "bytes": freshPayload.base64EncodedString()])!
        newOut.fileHandleForWriting.write(freshFrame)
        let decoded = try await waitForNonEmptyRead(stdoutCapture.fileHandleForReading.fileDescriptor)
        XCTAssertEqual(decoded, freshPayload, "the current-generation handle's own frame must still decode normally")
    }

    // MARK: - a surface that stops draining

    /// The one the whole write path exists for. A pane's frame write runs
    /// inside the herdr-output handler, so a write that does not return while
    /// the surface stops taking bytes parks that handler, every other write
    /// queued behind its lock, and the drain of herdr's own output with it.
    func testWriteToAStalledReaderReturnsPromptly() {
        let stalled = Pipe()
        let channel = BridgeWriteChannel(fd: stalled.fileHandleForWriting.fileDescriptor, name: "stall-test")
        // Well past the 64 KiB a macOS pipe grows to, so the far end is full
        // long before the last byte.
        let payload = Data(repeating: 0x41, count: 512 * 1024)
        let outcome = LockedBox(BridgeWriteChannel.Outcome.failed)
        let returned = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInteractive).async {
            let result = channel.write(payload)
            outcome.mutate { $0 = result }
            returned.signal()
        }

        let promptly = returned.wait(timeout: .now() + 2) == .success
        // Drained before the assertion, never after: a failure otherwise
        // leaves a thread parked in write() for the rest of the run, on a
        // descriptor whose number a later test's pipe can reclaim.
        _ = drainForTest(stalled.fileHandleForReading.fileDescriptor, for: .seconds(2))
        _ = returned.wait(timeout: .now() + 5)

        XCTAssertTrue(promptly, "a reader that stopped draining parked the writer")
        XCTAssertEqual(outcome.value, .queued, "bytes the far end would not take must be held, not dropped")
    }

    /// Unbounded buffering only moves the failure from a hang to memory
    /// growth. A far end that has left megabytes unread is gone, so the
    /// channel stops accepting outright rather than quietly discarding part
    /// of a stream: no caller is ever told bytes went when they did not.
    func testAChannelPastItsBoundRefusesEverythingAndSaysSo() {
        let stalled = Pipe()
        let overflowed = DispatchSemaphore(value: 0)
        let channel = BridgeWriteChannel(
            fd: stalled.fileHandleForWriting.fileDescriptor, name: "bound-test",
            limit: 128 * 1024, onOverflow: { overflowed.signal() }
        )

        var outcome = BridgeWriteChannel.Outcome.delivered
        var attempts = 0
        while outcome != .failed, attempts < 64 {
            outcome = channel.write(Data(repeating: 0x41, count: 32 * 1024))
            attempts += 1
        }

        XCTAssertEqual(outcome, .failed, "the buffer grew past its bound without refusing anything")
        XCTAssertEqual(overflowed.wait(timeout: .now() + 2), .success, "the bound was hit without telling the owner")
        XCTAssertEqual(
            channel.write(Data("late".utf8)), .failed,
            "a channel past its bound must never accept anything again")
        XCTAssertEqual(channel.queuedByteCount, 0)
        drainForTest(stalled.fileHandleForReading.fileDescriptor, for: .milliseconds(200))
    }

    /// What `PTYResizeRelay` rests on: a queued write reports delivery when
    /// its own last byte leaves, never when it is accepted.
    func testAQueuedWriteReportsDeliveryOnlyOnceItsBytesHaveLeft() {
        let stalled = Pipe()
        let channel = BridgeWriteChannel(fd: stalled.fileHandleForWriting.fileDescriptor, name: "delivery-test")
        let delivered = DispatchSemaphore(value: 0)

        XCTAssertEqual(channel.write(Data(repeating: 0x41, count: 256 * 1024)), .queued)
        XCTAssertEqual(channel.write(Data("tail".utf8), onDelivered: { delivered.signal() }), .queued)

        XCTAssertEqual(
            delivered.wait(timeout: .now() + 0.3), .timedOut,
            "a write still standing in the buffer reported itself delivered")
        drainForTest(stalled.fileHandleForReading.fileDescriptor, for: .seconds(2))
        XCTAssertEqual(
            delivered.wait(timeout: .now() + 2), .success,
            "the far end took every byte and the write never reported it")
    }

    /// These are terminal bytes: a chunk dropped or reordered lands mid escape
    /// sequence and corrupts the pane's screen. A stall may delay the stream
    /// and must never reshape it.
    func testFrameBytesCrossAStallInOrderAndExactlyOnce() {
        let fromHerdr = Pipe()
        let toSurface = Pipe()
        let io = BridgeIO(
            herdrInFD: Pipe().fileHandleForWriting.fileDescriptor,
            stdinFD: Pipe().fileHandleForReading.fileDescriptor,
            stdoutFD: toSurface.fileHandleForWriting.fileDescriptor,
            onPeerGone: { _ in }
        )
        defer { io.close() }
        io.startHerdrOutput(fromHerdr.fileHandleForReading)

        var expected = Data()
        var feed = Data()
        for index in 0..<64 {
            let payload = Data("[\(index)]\(String(repeating: "x", count: 4_000))".utf8)
            expected.append(payload)
            feed.append(ControlBridge.encodeLine([
                "type": "terminal.frame", "bytes": payload.base64EncodedString(),
            ])!)
        }

        let herdrFD = fromHerdr.fileHandleForWriting.fileDescriptor
        let stream = feed
        let fed = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInteractive).async {
            _ = writeAllForTest(herdrFD, stream)
            fed.signal()
        }
        // The surface takes nothing until every frame has been handed over,
        // so what is asserted below really did cross a stall rather than
        // trickling out behind a reader that kept up.
        let handedOverDuringTheStall = fed.wait(timeout: .now() + 3) == .success
        let collected = collectForTest(
            toSurface.fileHandleForReading.fileDescriptor, bytes: expected.count, timeout: .seconds(10))
        _ = fed.wait(timeout: .now() + 5)

        XCTAssertTrue(handedOverDuringTheStall, "the bridge stopped taking frames while the surface was stalled")
        XCTAssertEqual(collected.count, expected.count, "the stall lost bytes")
        XCTAssertTrue(collected == expected, "every frame's bytes, once each, in the order herdr sent them")
    }

    /// The other half of the deadlock. The frame write runs on the
    /// herdr-output handler's own queue, so a parked write stops the bridge
    /// reading herdr at all. The status line below is reachable only by a
    /// handler that went on draining while the surface took nothing.
    func testHerdrOutputKeepsDrainingWhileTheSurfaceIsStalled() {
        let fromHerdr = Pipe()
        let toSurface = Pipe()
        let statusCapture = Pipe()
        let io = BridgeIO(
            herdrInFD: Pipe().fileHandleForWriting.fileDescriptor,
            stdinFD: Pipe().fileHandleForReading.fileDescriptor,
            stdoutFD: toSurface.fileHandleForWriting.fileDescriptor,
            statusFD: statusCapture.fileHandleForWriting.fileDescriptor,
            onPeerGone: { _ in }
        )
        defer { io.close() }
        io.startHerdrOutput(fromHerdr.fileHandleForReading)

        var feed = Data()
        for _ in 0..<40 {
            let payload = Data(String(repeating: "f", count: 8_000).utf8)
            feed.append(ControlBridge.encodeLine([
                "type": "terminal.frame", "bytes": payload.base64EncodedString(),
            ])!)
        }
        feed.append(ControlBridge.encodeLine(["type": "terminal.mouse_capture", "enabled": true])!)

        let herdrFD = fromHerdr.fileHandleForWriting.fileDescriptor
        let stream = feed
        let fed = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInteractive).async {
            _ = writeAllForTest(herdrFD, stream)
            fed.signal()
        }

        let status = collectForTest(
            statusCapture.fileHandleForReading.fileDescriptor, bytes: 1, timeout: .seconds(5))
        _ = drainForTest(toSurface.fileHandleForReading.fileDescriptor, for: .seconds(2))
        _ = fed.wait(timeout: .now() + 5)

        XCTAssertTrue(
            String(decoding: status, as: UTF8.self).contains("flock.mouse_capture"),
            "herdr's output stopped being drained while the surface was stalled")
    }

    /// The relay's contract through a stall: a size counts as herdr's only
    /// once its bytes have really left, so a resize that had to queue is
    /// recorded when it flushes and never sent twice afterward. Recording it
    /// on the attempt would leave the relay believing herdr has a size that
    /// could still be dropped; never recording it would resend that size for
    /// the pane's whole life.
    func testAResizeQueuedBehindAStalledChildIsRecordedOnlyOnceItFlushes() {
        let herdrIn = Pipe()
        let winsize = LockedBox(PTYSize(cols: 30, rows: 40))
        let io = BridgeIO(
            herdrInFD: herdrIn.fileHandleForWriting.fileDescriptor,
            stdinFD: Pipe().fileHandleForReading.fileDescriptor,
            stdoutFD: Pipe().fileHandleForWriting.fileDescriptor,
            spawnedSize: PTYSize(cols: 30, rows: 40), ptySize: { winsize.value },
            onPeerGone: { _ in }
        )
        defer { io.close() }

        // A child that has stopped reading its own stdin: everything from
        // here has to stand in the buffer.
        let filler = Data(repeating: 0x41, count: 256 * 1024).base64EncodedString()
        XCTAssertEqual(
            io.send(["type": "terminal.input", "bytes": filler]), .queued,
            "the child's stdin never filled, so nothing below ever queued")

        winsize.mutate { $0 = PTYSize(cols: 60, rows: 41) }
        io.startPTYSizeRelay()
        winsize.mutate { $0 = PTYSize(cols: 61, rows: 42) }
        io.startPTYSizeRelay()

        let flushed = collectLinesForTest(herdrIn.fileHandleForReading.fileDescriptor, for: .seconds(3))
        io.startPTYSizeRelay()
        let afterFlush = collectLinesForTest(herdrIn.fileHandleForReading.fileDescriptor, for: .milliseconds(500))

        XCTAssertEqual(
            flushed.compactMap(resizeDimsForTest), [[60, 41], [61, 42]],
            "each new size, once, in the order the PTY took them")
        XCTAssertEqual(
            afterFlush.compactMap(resizeDimsForTest), [],
            "a size herdr has already been sent was owed all over again")
    }
}

/// A plain locked box for accumulating values from a `DispatchSource`
/// event handler (a background queue) and reading them back from the test's
/// own thread.
private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T

    init(_ initial: T) {
        stored = initial
    }

    var value: T {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func mutate(_ body: (inout T) -> Void) {
        lock.lock(); defer { lock.unlock() }
        body(&stored)
    }
}

// MARK: - child-process helpers

private func spawnTestChild(script: String, standardOutput: Any? = nil) -> Process {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/sh")
    proc.arguments = ["-c", script]
    proc.standardOutput = standardOutput ?? FileHandle.nullDevice
    proc.standardError = FileHandle.nullDevice
    try? proc.run()
    return proc
}

/// Whether `marker` appeared on `fd` before `timeout` ran out, accumulating
/// across polls because a short write can arrive in pieces.
private func waitForOutput(_ marker: String, on fd: Int32, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    var accumulated = Data()
    while Date() < deadline {
        accumulated.append(readAllAvailableForTest(fd))
        if String(decoding: accumulated, as: UTF8.self).contains(marker) { return true }
        usleep(5_000)
    }
    return false
}

/// Whether `process` was still running when `timeout` ran out. Polls rather
/// than `waitUntilExit()`, which would block for the child's whole lifetime
/// and turn "it was killed" into "it eventually exited on its own".
private func waitForExit(_ process: Process, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning, Date() < deadline {
        usleep(10_000)
    }
    return process.isRunning
}

// MARK: - polling helpers

private func waitForNonEmptyRead(_ fd: Int32, timeout: Duration = .seconds(5)) async throws -> Data {
    let deadline = ContinuousClock.now + timeout
    while true {
        let data = readAllAvailableForTest(fd)
        if !data.isEmpty { return data }
        if ContinuousClock.now >= deadline { throw BridgeTimeoutError() }
        try await Task.sleep(for: .milliseconds(20))
    }
}

/// Like `waitForNonEmptyRead`, but keeps accumulating across polls until at
/// least `lines` newline-delimited records have arrived -- several `send()`
/// calls from one control-pipe event handler invocation can each reach the
/// reading end on their own schedule, so a single non-empty read is not
/// enough to guarantee every expected line has landed yet.
private func waitForNonEmptyReadOfAtLeast(_ fd: Int32, lines: Int, timeout: Duration = .seconds(5)) async throws -> Data {
    let deadline = ContinuousClock.now + timeout
    var accumulated = Data()
    while true {
        accumulated.append(readAllAvailableForTest(fd))
        if accumulated.split(separator: 0x0A).count >= lines { return accumulated }
        if ContinuousClock.now >= deadline { throw BridgeTimeoutError() }
        try await Task.sleep(for: .milliseconds(20))
    }
}

/// Writes every byte, blocking for as long as the far end needs, the way a
/// real herdr child's own stdout write does.
private func writeAllForTest(_ fd: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { raw -> Bool in
        guard let base = raw.baseAddress else { return false }
        var sent = 0
        while sent < raw.count {
            let n = write(fd, base.advanced(by: sent), raw.count - sent)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return false }
            sent += n
        }
        return true
    }
}

/// Accumulates until `bytes` have arrived or the timeout runs out; returns
/// whatever did arrive, so the caller can say how much was missing.
private func collectForTest(_ fd: Int32, bytes: Int, timeout: Duration) -> Data {
    let deadline = ContinuousClock.now + timeout
    var collected = Data()
    while collected.count < bytes, ContinuousClock.now < deadline {
        let chunk = readAllAvailableForTest(fd)
        if chunk.isEmpty {
            usleep(2_000)
        } else {
            collected.append(chunk)
        }
    }
    return collected
}

/// Everything that arrives over `duration`, split into NDJSON records.
private func collectLinesForTest(_ fd: Int32, for duration: Duration) -> [Data] {
    let deadline = ContinuousClock.now + duration
    var accumulated = Data()
    while ContinuousClock.now < deadline {
        let chunk = readAllAvailableForTest(fd)
        if chunk.isEmpty {
            usleep(2_000)
        } else {
            accumulated.append(chunk)
        }
    }
    return accumulated.split(separator: 0x0A).map(Data.init)
}

/// `[cols, rows]` for a `terminal.resize` line, nil for anything else.
private func resizeDimsForTest(_ line: Data) -> [Int]? {
    guard
        let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
        object["type"] as? String == "terminal.resize",
        let cols = object["cols"] as? Int, let rows = object["rows"] as? Int
    else { return nil }
    return [cols, rows]
}

/// Reads and discards for `duration`. Also the release valve for a test that
/// stalled a reader on purpose: a writer parked on a full pipe returns the
/// moment its bytes are taken.
@discardableResult
private func drainForTest(_ fd: Int32, for duration: Duration) -> Int {
    let deadline = ContinuousClock.now + duration
    var drained = 0
    while ContinuousClock.now < deadline {
        let chunk = readAllAvailableForTest(fd)
        if chunk.isEmpty {
            usleep(2_000)
        } else {
            drained += chunk.count
        }
    }
    return drained
}

func readAllAvailableForTest(_ fd: Int32) -> Data {
    let flags = fcntl(fd, F_GETFL, 0)
    if flags & O_NONBLOCK == 0 {
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = read(fd, &buffer, buffer.count)
        if n <= 0 { break }
        result.append(contentsOf: buffer.prefix(n))
    }
    return result
}
