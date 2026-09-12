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
/// encode/decode/filter functions, and `BridgeIO` wired to plain anonymous
/// pipes standing in for the PTY and for herdr's own pipes -- so the real
/// process-spawning integration is left to the manual smoke test (brief
/// Step 5), and everything that can be exercised without a real herdr child
/// is exercised here.
final class ControlBridgeTests: XCTestCase {
    // MARK: - BridgeOptions

    func testBridgeOptionsParsesAllFlags() {
        let options = BridgeOptions(arguments: [
            "--bridge", "w1:p1",
            "--cols", "120", "--rows", "40",
            "--socket", "/tmp/a.sock",
            "--herdr-bin", "/opt/homebrew/bin/herdr",
            "--control-pipe", "/tmp/ctl.fifo",
        ], environment: [:])
        XCTAssertEqual(options.target, "w1:p1")
        XCTAssertEqual(options.cols, 120)
        XCTAssertEqual(options.rows, 40)
        XCTAssertEqual(options.socketPath, "/tmp/a.sock")
        XCTAssertEqual(options.herdrBinary, "/opt/homebrew/bin/herdr")
        XCTAssertEqual(options.controlPipe, "/tmp/ctl.fifo")
    }

    func testBridgeOptionsFallsBackToEnvironmentWhenFlagsAbsent() {
        let options = BridgeOptions(arguments: [], environment: [
            "HERDR_TERM_TARGET": "w2:p3",
            "HERDR_SOCKET_PATH": "/tmp/env.sock",
            "HERDR_BIN": "/usr/local/bin/herdr",
            PaneControlChannel.environmentKey: "/tmp/env-ctl.fifo",
        ])
        XCTAssertEqual(options.target, "w2:p3")
        XCTAssertNil(options.cols)
        XCTAssertNil(options.rows)
        XCTAssertEqual(options.socketPath, "/tmp/env.sock")
        XCTAssertEqual(options.herdrBinary, "/usr/local/bin/herdr")
        XCTAssertEqual(options.controlPipe, "/tmp/env-ctl.fifo")
    }

    func testBridgeOptionsFlagWinsOverEnvironment() {
        let options = BridgeOptions(
            arguments: ["--bridge", "flag-target"],
            environment: ["HERDR_TERM_TARGET": "env-target"]
        )
        XCTAssertEqual(options.target, "flag-target")
    }

    func testBridgeOptionsMissingTargetIsEmpty() {
        let options = BridgeOptions(arguments: ["--cols", "80"], environment: [:])
        XCTAssertEqual(options.target, "")
    }

    func testArgvRoundTripsThroughBridgeOptions() {
        let argv = BridgeOptions.argv(
            executablePath: "/Applications/Paddock.app/Contents/MacOS/Paddock",
            target: "w3:p2",
            cols: 100,
            rows: 30,
            socketPath: "/tmp/round.sock",
            herdrBinary: "/opt/homebrew/bin/herdr",
            controlPipe: "/tmp/round-ctl.fifo"
        )
        // First element is the executable path, not a flag; BridgeOptions
        // only ever parses arguments AFTER argv[0].
        let options = BridgeOptions(arguments: Array(argv.dropFirst()), environment: [:])
        XCTAssertEqual(options.target, "w3:p2")
        XCTAssertEqual(options.cols, 100)
        XCTAssertEqual(options.rows, 30)
        XCTAssertEqual(options.socketPath, "/tmp/round.sock")
        XCTAssertEqual(options.herdrBinary, "/opt/homebrew/bin/herdr")
        XCTAssertEqual(options.controlPipe, "/tmp/round-ctl.fifo")
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

    // MARK: - startupResize

    func testStartupResizeNilWhenUnchanged() {
        let size = PTYSize(cols: 80, rows: 24)
        XCTAssertNil(ControlBridge.startupResize(spawned: size, current: size))
    }

    func testStartupResizeReturnsCurrentWhenChanged() {
        let spawned = PTYSize(cols: 80, rows: 24)
        let current = PTYSize(cols: 120, rows: 40)
        XCTAssertEqual(ControlBridge.startupResize(spawned: spawned, current: current), current)
    }

    func testStartupResizeNilWhenCurrentIsZero() {
        let spawned = PTYSize(cols: 80, rows: 24)
        XCTAssertNil(ControlBridge.startupResize(spawned: spawned, current: PTYSize(cols: 0, rows: 0)))
    }

    // MARK: - childArgv (mode-switching bridge)

    func testChildArgvObserveModeHasNoTakeoverFlag() {
        let argv = ControlBridge.childArgv(mode: .observe, target: "w1:p1", cols: 120, rows: 40)
        XCTAssertEqual(argv, ["terminal", "session", "observe", "w1:p1", "--cols", "120", "--rows", "40"])
    }

    func testChildArgvControlModeIncludesTakeover() {
        let argv = ControlBridge.childArgv(mode: .control, target: "w1:p1", cols: 120, rows: 40)
        XCTAssertEqual(
            argv, ["terminal", "session", "control", "w1:p1", "--takeover", "--cols", "120", "--rows", "40"])
    }

    // MARK: - decodeFrame / encodeInput / parseForwardableControlCommand

    func testDecodeFrameValid() {
        let line = ControlBridge.encodeLine(["type": "terminal.frame", "bytes": Data("hello".utf8).base64EncodedString()])!
        XCTAssertEqual(ControlBridge.decodeFrame(line.dropLast()), Data("hello".utf8))
    }

    func testDecodeFrameRejectsWrongType() {
        let line = ControlBridge.encodeLine(["type": "terminal.closed"])!
        XCTAssertNil(ControlBridge.decodeFrame(line.dropLast()))
    }

    func testDecodeFrameRejectsMalformedJSON() {
        XCTAssertNil(ControlBridge.decodeFrame(Data("not json at all".utf8)))
    }

    func testDecodeFrameRejectsEmptyDecodedBytes() {
        let line = ControlBridge.encodeLine(["type": "terminal.frame", "bytes": ""])!
        XCTAssertNil(ControlBridge.decodeFrame(line.dropLast()))
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

    /// Scroll must never cross the FIFO, even though it is otherwise a
    /// well-formed `terminal.*` command.
    func testParseForwardableControlCommandRejectsScroll() {
        let line = ControlBridge.encodeLine([
            "type": "terminal.scroll", "direction": "up", "lines": 5, "source": "wheel",
        ])!
        XCTAssertNil(ControlBridge.parseForwardableControlCommand(line.dropLast()))
    }

    func testParseForwardableControlCommandRejectsNonTerminalType() {
        let line = ControlBridge.encodeLine(["type": "session.hello"])!
        XCTAssertNil(ControlBridge.parseForwardableControlCommand(line.dropLast()))
    }

    func testParseForwardableControlCommandRejectsMalformedJSON() {
        XCTAssertNil(ControlBridge.parseForwardableControlCommand(Data("{not json".utf8)))
    }

    // MARK: - parseModeCommand

    func testParseModeCommandAcceptsControlAndObserve() {
        let controlLine = ControlBridge.encodeLine(["type": "paddock.mode", "mode": "control"])!
        XCTAssertEqual(ControlBridge.parseModeCommand(controlLine.dropLast()), .control)
        let observeLine = ControlBridge.encodeLine(["type": "paddock.mode", "mode": "observe"])!
        XCTAssertEqual(ControlBridge.parseModeCommand(observeLine.dropLast()), .observe)
    }

    /// An unknown mode value is ignored (`nil`), not a crash -- see the
    /// control-pipe test below for proof this does not kill the loop.
    func testParseModeCommandRejectsUnknownMode() {
        let line = ControlBridge.encodeLine(["type": "paddock.mode", "mode": "bogus"])!
        XCTAssertNil(ControlBridge.parseModeCommand(line.dropLast()))
    }

    func testParseModeCommandRejectsNonModeType() {
        let line = ControlBridge.encodeLine(["type": "terminal.input", "bytes": "aGk="])!
        XCTAssertNil(ControlBridge.parseModeCommand(line.dropLast()))
    }

    func testParseModeCommandRejectsMalformedJSON() {
        XCTAssertNil(ControlBridge.parseModeCommand(Data("{not json".utf8)))
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

    func testControlPipeForwardsInputButDropsScroll() async throws {
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

        let forwarded = try await waitForNonEmptyRead(herdrIn.fileHandleForReading.fileDescriptor)
        let lines = forwarded.split(separator: 0x0A)
        XCTAssertEqual(lines.count, 1, "only the non-scroll command should have been forwarded")
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(lines[0])) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "terminal.input")

        // Give a would-be second (scroll) line every chance to have arrived
        // before declaring victory.
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(readAllAvailableForTest(herdrIn.fileHandleForReading.fileDescriptor).count, 0)
    }

    func testStdinEncodesToTerminalInputThenReleaseOnEOF() async throws {
        let stdinStandIn = Pipe()
        let herdrIn = Pipe()
        let io = BridgeIO(
            herdrInFD: herdrIn.fileHandleForWriting.fileDescriptor,
            stdinFD: stdinStandIn.fileHandleForReading.fileDescriptor,
            stdoutFD: Pipe().fileHandleForWriting.fileDescriptor,
            mode: .control,
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

    // MARK: - mode-gated stdin (observe mode has no input path)

    /// Observe mode is the bridge's own default and the pane's unfocused
    /// steady state: bytes off the PTY are read (so it never blocks) but
    /// never written to the herdr child.
    func testStdinBytesInObserveModeAreDiscardedNotForwarded() async throws {
        let stdinStandIn = Pipe()
        let herdrIn = Pipe()
        let io = BridgeIO(
            herdrInFD: herdrIn.fileHandleForWriting.fileDescriptor,
            stdinFD: stdinStandIn.fileHandleForReading.fileDescriptor,
            stdoutFD: Pipe().fileHandleForWriting.fileDescriptor,
            mode: .observe,
            onPeerGone: {}
        )
        io.startStdin()

        stdinStandIn.fileHandleForWriting.write(Data("echo hi\r".utf8))
        // Give a would-be forward every chance to have arrived before
        // declaring victory.
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(readAllAvailableForTest(herdrIn.fileHandleForReading.fileDescriptor).count, 0)
    }

    /// `setMode(.control)` flips the gate live, matching a real mode switch:
    /// bytes typed before the switch are dropped, bytes typed after are
    /// forwarded.
    func testSetModeToControlStartsForwardingStdin() async throws {
        let stdinStandIn = Pipe()
        let herdrIn = Pipe()
        let io = BridgeIO(
            herdrInFD: herdrIn.fileHandleForWriting.fileDescriptor,
            stdinFD: stdinStandIn.fileHandleForReading.fileDescriptor,
            stdoutFD: Pipe().fileHandleForWriting.fileDescriptor,
            mode: .observe,
            onPeerGone: {}
        )
        io.startStdin()
        io.setMode(.control)

        let typed = Data("hi\r".utf8)
        stdinStandIn.fileHandleForWriting.write(typed)
        let forwarded = try await waitForNonEmptyRead(herdrIn.fileHandleForReading.fileDescriptor)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: forwarded.split(separator: 0x0A)[0]) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "terminal.input")
    }

    // MARK: - control pipe: paddock.mode never forwarded, unknown mode ignored

    func testModeCommandLineIsNeverForwardedToHerdrButFiresTheCallback() async throws {
        let control = Pipe()
        let herdrIn = Pipe()
        let io = BridgeIO(
            herdrInFD: herdrIn.fileHandleForWriting.fileDescriptor,
            stdinFD: Pipe().fileHandleForReading.fileDescriptor,
            stdoutFD: Pipe().fileHandleForWriting.fileDescriptor,
            onPeerGone: {}
        )
        let receivedModes = LockedBox<[PaneMode]>([])
        io.onModeCommand = { mode in receivedModes.mutate { $0.append(mode) } }
        io.startControlPipe(fd: control.fileHandleForReading.fileDescriptor, closeOnCancel: false)

        let modeLine = ControlBridge.encodeLine(["type": "paddock.mode", "mode": "control"])!
        let inputLine = ControlBridge.encodeLine(["type": "terminal.input", "bytes": "aGk="])!
        control.fileHandleForWriting.write(modeLine)
        control.fileHandleForWriting.write(inputLine)

        // The mode line's own effect: the callback fires, never a forwarded
        // herdr line for it.
        let forwarded = try await waitForNonEmptyRead(herdrIn.fileHandleForReading.fileDescriptor)
        let lines = forwarded.split(separator: 0x0A)
        XCTAssertEqual(lines.count, 1, "only the terminal.input line is ever forwarded")
        XCTAssertEqual(receivedModes.value, [.control])
    }

    /// An unknown mode does not kill the control-pipe loop: the line after
    /// it still parses and forwards normally.
    func testUnknownModeIsIgnoredWithoutKillingTheControlLoop() async throws {
        let control = Pipe()
        let herdrIn = Pipe()
        let io = BridgeIO(
            herdrInFD: herdrIn.fileHandleForWriting.fileDescriptor,
            stdinFD: Pipe().fileHandleForReading.fileDescriptor,
            stdoutFD: Pipe().fileHandleForWriting.fileDescriptor,
            onPeerGone: {}
        )
        let receivedModes = LockedBox<[PaneMode]>([])
        io.onModeCommand = { mode in receivedModes.mutate { $0.append(mode) } }
        io.startControlPipe(fd: control.fileHandleForReading.fileDescriptor, closeOnCancel: false)

        let bogusModeLine = ControlBridge.encodeLine(["type": "paddock.mode", "mode": "bogus"])!
        let inputLine = ControlBridge.encodeLine(["type": "terminal.input", "bytes": "aGk="])!
        control.fileHandleForWriting.write(bogusModeLine)
        control.fileHandleForWriting.write(inputLine)

        let forwarded = try await waitForNonEmptyRead(herdrIn.fileHandleForReading.fileDescriptor)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: forwarded.split(separator: 0x0A)[0]) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "terminal.input", "the line after an unknown mode must still parse and forward")
        XCTAssertTrue(receivedModes.value.isEmpty, "an unrecognized mode never reaches the callback")
    }

    // MARK: - BridgeModeSwitcher (mode switch tears down old child, spawns the other verb)

    func testRequestSwitchTerminatesOldChildAndSpawnsOtherVerbAtLatestSize() {
        let spawnedModes = LockedBox<[(PaneMode, PTYSize)]>([])
        let terminatedModes = LockedBox<[PaneMode]>([])
        let herdrIn = Pipe()
        let io = BridgeIO(herdrInFD: -1, onPeerGone: {})

        func fakeChild(mode: PaneMode) -> BridgeChild {
            BridgeChild(
                mode: mode, process: Process(), toHerdrFD: herdrIn.fileHandleForWriting.fileDescriptor,
                fromHerdrHandle: Pipe().fileHandleForReading)
        }

        let initial = fakeChild(mode: .observe)
        let switcher = BridgeModeSwitcher(
            initial: initial, size: PTYSize(cols: 80, rows: 24), io: io,
            spawnChild: { mode, size in
                spawnedModes.mutate { $0.append((mode, size)) }
                return fakeChild(mode: mode)
            },
            terminateChild: { child in terminatedModes.mutate { $0.append(child.mode) } }
        )

        switcher.recordSize(PTYSize(cols: 120, rows: 40))
        switcher.requestSwitch(to: .control)

        XCTAssertEqual(terminatedModes.value, [.observe], "the OLD child is terminated before the new one spawns")
        XCTAssertEqual(spawnedModes.value.count, 1)
        XCTAssertEqual(spawnedModes.value.first?.0, .control, "the replacement is the OTHER verb")
        XCTAssertEqual(spawnedModes.value.first?.1, PTYSize(cols: 120, rows: 40), "spawned at the LATEST known size, not the size the switcher was created with")
        XCTAssertEqual(switcher.currentMode, .control)
    }

    func testRequestSwitchToTheSameModeIsANoOp() {
        let spawnCount = LockedBox<Int>(0)
        let herdrIn = Pipe()
        let io = BridgeIO(herdrInFD: -1, onPeerGone: {})
        let initial = BridgeChild(
            mode: .observe, process: Process(), toHerdrFD: herdrIn.fileHandleForWriting.fileDescriptor,
            fromHerdrHandle: Pipe().fileHandleForReading)
        let switcher = BridgeModeSwitcher(
            initial: initial, size: PTYSize(cols: 80, rows: 24), io: io,
            spawnChild: { mode, _ in
                spawnCount.mutate { $0 += 1 }
                return BridgeChild(
                    mode: mode, process: Process(), toHerdrFD: herdrIn.fileHandleForWriting.fileDescriptor,
                    fromHerdrHandle: Pipe().fileHandleForReading)
            },
            terminateChild: { _ in XCTFail("must not terminate anything for a same-mode request") }
        )

        switcher.requestSwitch(to: .observe)

        XCTAssertEqual(spawnCount.value, 0)
        XCTAssertEqual(switcher.currentMode, .observe)
    }

    /// A bounded, real-process exercise of the escalation timing itself
    /// (SIGTERM, wait, SIGKILL fallback), independent of any herdr binary:
    /// `/bin/sleep` stands in for a wedged child that ignores SIGTERM.
    func testTerminateWithBoundedEscalationKillsAProcessThatIgnoresSIGTERM() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", "trap '' TERM; sleep 30"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        guard proc.isRunning else { return XCTFail("failed to spawn the test child") }

        terminateWithBoundedEscalation(proc, timeout: 0.2)

        XCTAssertFalse(proc.isRunning, "SIGKILL fallback must have ended the process")
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
