import AppKit
import Darwin
import XCTest
@testable import FlockCore

/// What one keystroke costs on flock's side of the wire, measured rather than
/// assumed. Three legs are reachable with no herdr and no launched app:
///
/// 1. the AppKit text-input pass `GhosttySurfaceView.keyDown` runs
///    (`interpretKeyEvents`, plus the accumulator it fills),
/// 2. the bridge's stdin leg -- PTY bytes in, one `terminal.input` line out to
///    herdr's stdin,
/// 3. the bridge's frame leg -- one `terminal.frame` line in from herdr, its
///    bytes out to the PTY.
///
/// Everything between them (libghostty's own key encode, the two PTY hops,
/// herdr itself) needs a real session and is not measured here; the report
/// says so rather than guessing at it.
///
/// Numbers are printed, and the assertions are budgets an order of magnitude
/// above what the path costs today: they exist to catch a regression that
/// changes the shape of the cost, not to pin a machine's exact speed.
@MainActor
final class KeyPathLatencyTests: XCTestCase {
    private static let iterations = 2_000

    /// The text-input pass, on a stand-in that fills an accumulator from
    /// `insertText` exactly the way the pane's surface does. A real
    /// `GhosttySurfaceView` cannot stand in: entering a window makes it build
    /// a libghostty surface, which spawns this pane's bridge child.
    func testInterpretKeyEventsCostPerKeystroke() throws {
        let window = offscreenWindow()
        let view = AccumulatingInputView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView?.addSubview(view)
        XCTAssertTrue(window.makeFirstResponder(view))
        let event = try XCTUnwrap(keyEvent(characters: "a", keyCode: 0, in: window))

        // Warm: the first call into the text-input system builds the keyboard
        // layout map, which is milliseconds once per process and never again.
        view.run(event)
        let perKeystroke = measureMicroseconds { view.run(event) }
        XCTAssertGreaterThan(view.collected, 0, "the accumulator never filled, so this measured an empty path")
        print("KEYPATH interpretKeyEvents+accumulator: \(String(format: "%.1f", perKeystroke))us per keystroke")
        XCTAssertLessThan(perKeystroke, 500, "the text-input pass now costs half a millisecond a keystroke")
    }

    /// Everything `keyDown` does around the text-input pass, on the real view
    /// with no surface attached: the focus gate, the accumulator's own
    /// allocation and join, and the guard `sendKeyDown` returns on.
    func testKeyDownSurroundCostPerKeystroke() throws {
        let host = try XCTUnwrap(try? GhosttyHost(), "libghostty would not initialize")
        let session = host.makeSession(
            paneID: PaneID(rawValue: "w1:p1"),
            configuration: GhosttySession.Launch(commandArgv: ["/usr/bin/true"], themeColors: Self.colors)
        )
        XCTAssertNil(session.surface, "a session that never attached must have no surface to spawn a child for")
        let view = GhosttySurfaceView(session: session)
        view.wantsFocus = true
        let event = try XCTUnwrap(keyEvent(characters: "a", keyCode: 0, in: nil))

        view.keyDown(with: event)
        let perKeystroke = measureMicroseconds { view.keyDown(with: event) }
        print("KEYPATH keyDown surround (no surface, no window): \(String(format: "%.1f", perKeystroke))us per keystroke")
        XCTAssertLessThan(perKeystroke, 500)
    }

    /// The floor every leg below is measured against: one byte through a
    /// plain pipe with nothing of flock's in the way, so the bridge's own cost
    /// is the difference rather than the whole number.
    func testRawPipeHopBaseline() throws {
        let pipe = Pipe()
        let median = try medianHopMicroseconds(
            write: { pipe.fileHandleForWriting.write(Data("a".utf8)) },
            read: pipe.fileHandleForReading.fileDescriptor
        )
        print("KEYPATH raw pipe baseline: \(String(format: "%.0f", median))us median")
        XCTAssertLessThan(median, 20_000)
    }

    /// PTY bytes in, one `terminal.input` line out on herdr's stdin.
    func testBridgeStdinLegLatency() throws {
        let fromSurface = Pipe()
        let herdrIn = Pipe()
        let io = BridgeIO(
            herdrInFD: herdrIn.fileHandleForWriting.fileDescriptor,
            stdinFD: fromSurface.fileHandleForReading.fileDescriptor,
            stdoutFD: Pipe().fileHandleForWriting.fileDescriptor,
            onPeerGone: { _ in }
        )
        io.startStdin()
        let median = try medianHopMicroseconds(
            write: { fromSurface.fileHandleForWriting.write(Data("a".utf8)) },
            read: herdrIn.fileHandleForReading.fileDescriptor
        )
        print("KEYPATH bridge stdin leg: \(String(format: "%.0f", median))us median")
        XCTAssertLessThan(median, 20_000)
    }

    /// One `terminal.frame` line in from herdr, its bytes out to the PTY.
    func testBridgeFrameLegLatency() throws {
        let fromHerdr = Pipe()
        let toSurface = Pipe()
        let io = BridgeIO(
            herdrInFD: Pipe().fileHandleForWriting.fileDescriptor,
            stdinFD: Pipe().fileHandleForReading.fileDescriptor,
            stdoutFD: toSurface.fileHandleForWriting.fileDescriptor,
            onPeerGone: { _ in }
        )
        io.startHerdrOutput(fromHerdr.fileHandleForReading)
        // A frame the size of one 80x24 repaint, which is what a keystroke's
        // echo actually costs on the wire.
        let payload = Data(String(repeating: "x", count: 80 * 24).utf8)
        let line = try XCTUnwrap(ControlBridge.encodeLine([
            "type": "terminal.frame", "bytes": payload.base64EncodedString(),
        ]))
        let median = try medianHopMicroseconds(
            write: { fromHerdr.fileHandleForWriting.write(line) },
            read: toSurface.fileHandleForReading.fileDescriptor
        )
        print("KEYPATH bridge frame leg: \(String(format: "%.0f", median))us median")
        XCTAssertLessThan(median, 20_000)
    }

    // MARK: - Helpers

    private static let colors = GhosttyThemeColors(
        background: GhosttyThemeColor(red: 0, green: 0, blue: 0),
        foreground: GhosttyThemeColor(red: 255, green: 255, blue: 255),
        ansi: Array(repeating: GhosttyThemeColor(red: 128, green: 128, blue: 128), count: 16)
    )

    private func offscreenWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        return window
    }

    private func keyEvent(characters: String, keyCode: UInt16, in window: NSWindow?) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window?.windowNumber ?? 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode
        )
    }

    private func microseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1e6 + Double(duration.components.attoseconds) / 1e12
    }

    private func measureMicroseconds(_ body: () -> Void) -> Double {
        let elapsed = ContinuousClock().measure {
            for _ in 0..<Self.iterations { body() }
        }
        return microseconds(elapsed) / Double(Self.iterations)
    }

    /// The median of 50 hops. A reader thread is already blocked in `read`
    /// before the clock starts, so what is timed is the hop itself and one
    /// thread wakeup -- never a polling interval, which on this platform is
    /// milliseconds wide and would swamp the thing being measured.
    private func medianHopMicroseconds(write: () -> Void, read fd: Int32) throws -> Double {
        var samples: [Double] = []
        for _ in 0..<50 {
            let arrival = Arrival()
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .userInteractive).async {
                var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                let count = Darwin.read(fd, &buffer, buffer.count)
                arrival.at = ContinuousClock.now
                arrival.bytes = count
                done.signal()
            }
            // Long enough for the reader to reach its blocking `read`; outside
            // the measured interval either way.
            Thread.sleep(forTimeInterval: 0.003)
            let started = ContinuousClock.now
            write()
            guard done.wait(timeout: .now() + 2) == .success else { throw HopTimeout() }
            guard let at = arrival.at, arrival.bytes > 0 else { throw HopTimeout() }
            samples.append(microseconds(at - started))
        }
        samples.sort()
        return samples[samples.count / 2]
    }

    private final class Arrival: @unchecked Sendable {
        var at: ContinuousClock.Instant?
        var bytes = 0
    }

    private struct HopTimeout: Error {}
}

/// The pane surface's text-input shape with no libghostty behind it: the same
/// `interpretKeyEvents` call, filling the same kind of accumulator from
/// `insertText`.
@MainActor
private final class AccumulatingInputView: NSView, @preconcurrency NSTextInputClient {
    private(set) var collected = 0
    private var accumulator: [String]?

    override var acceptsFirstResponder: Bool { true }

    func run(_ event: NSEvent) {
        accumulator = []
        interpretKeyEvents([event])
        collected += accumulator?.joined().count ?? 0
        accumulator = nil
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard let text = string as? String else { return }
        if accumulator != nil { accumulator?.append(text) }
    }

    func hasMarkedText() -> Bool { false }
    func markedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {}
    func unmarkText() {}
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func characterIndex(for point: NSPoint) -> Int { 0 }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect { .zero }
    override func doCommand(by selector: Selector) {}
}
