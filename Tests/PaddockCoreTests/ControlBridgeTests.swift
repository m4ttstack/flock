import XCTest
@testable import PaddockCore
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
            executablePath: "/Applications/Paddock.app/Contents/MacOS/Paddock",
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
        XCTAssertEqual(relay.relay(PTYSize(cols: 60, rows: 41)), PTYSize(cols: 60, rows: 41))
        XCTAssertEqual(relay.relay(PTYSize(cols: 30, rows: 40)), PTYSize(cols: 30, rows: 40), "back to the spawn size is a change too")
    }

    func testRelayDropsAnUnchangedOrUnreadableWinsize() {
        var relay = PTYResizeRelay(spawned: PTYSize(cols: 30, rows: 40))
        XCTAssertNil(relay.relay(PTYSize(cols: 30, rows: 40)), "herdr was spawned at this size")
        XCTAssertEqual(relay.relay(PTYSize(cols: 60, rows: 41)), PTYSize(cols: 60, rows: 41))
        XCTAssertNil(relay.relay(PTYSize(cols: 60, rows: 41)), "herdr already has this size")
        XCTAssertNil(relay.relay(nil))
        XCTAssertNil(relay.relay(PTYSize(cols: 0, rows: 41)))
        XCTAssertNil(relay.relay(PTYSize(cols: 60, rows: 0)))
        XCTAssertEqual(relay.herdrSize, PTYSize(cols: 60, rows: 41), "an unreadable size forgets nothing")
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
        XCTAssertEqual(object["type"] as? String, "paddock.mouse_capture")
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
            onPeerGone: {}
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
    /// status FIFO as `paddock.mouse_capture`, never to the PTY stdout; a
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
            onPeerGone: {}
        )
        io.startHerdrOutput(fromHerdr.fileHandleForReading)

        let captureLine = ControlBridge.encodeLine([
            "type": "terminal.mouse_capture", "enabled": true, "sgr_pixels": false,
        ])!
        fromHerdr.fileHandleForWriting.write(captureLine)

        let status = try await waitForNonEmptyRead(statusCapture.fileHandleForReading.fileDescriptor)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: status.split(separator: 0x0A)[0]) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "paddock.mouse_capture")
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
            onPeerGone: {}
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
        XCTAssertEqual(object["type"] as? String, "paddock.first_frame")

        let full2 = ControlBridge.encodeLine([
            "type": "terminal.frame", "bytes": Data("full2".utf8).base64EncodedString(), "full": true,
        ])!
        fromHerdr.fileHandleForWriting.write(full2)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(
            readAllAvailableForTest(statusCapture.fileHandleForReading.fileDescriptor).count, 0,
            "first_frame must be emitted exactly once, ever, even across a later full frame")
    }

    func testHerdrOutputSkipsMalformedLineWithoutStoppingSubsequentFrames() async throws {
        let fromHerdr = Pipe()
        let stdoutCapture = Pipe()
        let herdrIn = Pipe()
        let io = BridgeIO(
            herdrInFD: herdrIn.fileHandleForWriting.fileDescriptor,
            stdinFD: Pipe().fileHandleForReading.fileDescriptor,
            stdoutFD: stdoutCapture.fileHandleForWriting.fileDescriptor,
            onPeerGone: {}
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
            onPeerGone: {}
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
            onPeerGone: {}
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
            onPeerGone: {}
        )
        io.close()
        io.send(["type": "terminal.resize", "cols": 80, "rows": 24])
        XCTAssertEqual(readAllAvailableForTest(herdrIn.fileHandleForReading.fileDescriptor).count, 0)
    }

    // MARK: - resize: only the PTY's own size, only from SIGWINCH or the startup read

    func testSIGWINCHSendsThePTYWinsize() async throws {
        let herdrIn = Pipe()
        let io = BridgeIO(
            herdrInFD: herdrIn.fileHandleForWriting.fileDescriptor,
            stdinFD: Pipe().fileHandleForReading.fileDescriptor,
            stdoutFD: Pipe().fileHandleForWriting.fileDescriptor,
            spawnedSize: PTYSize(cols: 30, rows: 40), ptySize: { PTYSize(cols: 60, rows: 41) },
            onPeerGone: {}
        )
        io.startWinch()

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
            onPeerGone: {}
        )
        io.startWinch()

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

    func testTheStartupReadSendsOnlyWhenThePTYLeftTheSpawnSize() throws {
        let moved = Pipe()
        BridgeIO(
            herdrInFD: moved.fileHandleForWriting.fileDescriptor,
            spawnedSize: PTYSize(cols: 30, rows: 40), ptySize: { PTYSize(cols: 60, rows: 41) },
            onPeerGone: {}
        ).relayPTYSize()
        let lines = readAllAvailableForTest(moved.fileHandleForReading.fileDescriptor).split(separator: 0x0A)
        XCTAssertEqual(lines.count, 1)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(lines.first))) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "terminal.resize")
        XCTAssertEqual(object["cols"] as? Int, 60)
        XCTAssertEqual(object["rows"] as? Int, 41)

        let still = Pipe()
        BridgeIO(
            herdrInFD: still.fileHandleForWriting.fileDescriptor,
            spawnedSize: PTYSize(cols: 30, rows: 40), ptySize: { PTYSize(cols: 30, rows: 40) },
            onPeerGone: {}
        ).relayPTYSize()
        XCTAssertEqual(readAllAvailableForTest(still.fileHandleForReading.fileDescriptor).count, 0)
    }

    /// The app has no way left to put a size in front of herdr: neither a
    /// `terminal.resize` nor a legacy `paddock.dims` line on the control FIFO
    /// reaches it, while ordinary input still does.
    func testTheControlPipeCarriesNoSizeToHerdr() async throws {
        let control = Pipe()
        let herdrIn = Pipe()
        let io = BridgeIO(
            herdrInFD: herdrIn.fileHandleForWriting.fileDescriptor,
            stdinFD: Pipe().fileHandleForReading.fileDescriptor,
            stdoutFD: Pipe().fileHandleForWriting.fileDescriptor,
            spawnedSize: PTYSize(cols: 30, rows: 40), ptySize: { PTYSize(cols: 30, rows: 40) },
            onPeerGone: {}
        )
        io.startControlPipe(fd: control.fileHandleForReading.fileDescriptor, closeOnCancel: false)

        control.fileHandleForWriting.write(ControlBridge.encodeLine(["type": "terminal.resize", "cols": 60, "rows": 41])!)
        control.fileHandleForWriting.write(ControlBridge.encodeLine(["type": "paddock.dims", "cols": 60, "rows": 41])!)
        control.fileHandleForWriting.write(ControlBridge.encodeLine(["type": "terminal.input", "bytes": "aGk="])!)

        let forwarded = try await waitForNonEmptyRead(herdrIn.fileHandleForReading.fileDescriptor)
        try await Task.sleep(for: .milliseconds(80))
        let lines = (forwarded + readAllAvailableForTest(herdrIn.fileHandleForReading.fileDescriptor)).split(separator: 0x0A)
        XCTAssertEqual(lines.count, 1, "only the input line reaches herdr")
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(lines.first))) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "terminal.input")
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
    /// in for the wedged child; SIGKILL only reaches THIS process, never the
    /// `sleep` it spawned, so that orphan is kept short enough to exit on its
    /// own well inside a test run.
    func testTerminateEscalatesToSIGKILLForAChildThatIgnoresSIGTERM() {
        let proc = spawnTestChild(script: "trap '' TERM; sleep 5")
        guard proc.isRunning else { return XCTFail("failed to spawn the test child") }
        defer { if proc.isRunning { kill(proc.processIdentifier, SIGKILL) } }
        // The shell installs the trap as its first statement, so a SIGTERM
        // delivered before that runs kills the child on the default
        // disposition. Wait for the trap, then prove the child really does
        // survive SIGTERM -- otherwise the assertion below passes without
        // SIGKILL ever mattering.
        usleep(300_000)
        proc.terminate()
        XCTAssertTrue(
            waitForExit(proc, timeout: 0.3),
            "the child must ignore SIGTERM, or this proves nothing about the escalation")

        terminateWithBoundedEscalation(proc, timeout: 0.2)

        // Waited for, not read instantly: SIGKILL is delivered synchronously
        // but `Process.isRunning` only clears once Foundation reaps the child.
        // The window is still far inside the child's own 5s lifetime, so a
        // missing SIGKILL leaves it running here.
        XCTAssertFalse(
            waitForExit(proc, timeout: 1.5),
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
            stdoutFD: stdoutCapture.fileHandleForWriting.fileDescriptor, onPeerGone: {})
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
            stdoutFD: stdoutCapture.fileHandleForWriting.fileDescriptor, onPeerGone: {})
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

private func spawnTestChild(script: String) -> Process {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/sh")
    proc.arguments = ["-c", script]
    proc.standardOutput = FileHandle.nullDevice
    proc.standardError = FileHandle.nullDevice
    try? proc.run()
    return proc
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

private func readAllAvailableForTest(_ fd: Int32) -> Data {
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
