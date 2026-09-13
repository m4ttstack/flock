import XCTest
@testable import PaddockCore

final class MouseForwardingTests: XCTestCase {
    private let cell = MouseForwarding.CellSize(width: 8, height: 16)

    private func decide(
        kind: MouseForwarding.EventKind = .down,
        button: MouseForwarding.Button? = .left,
        modifiers: UInt8 = 0,
        point: MouseForwarding.Point = .init(x: 0, y: 0),
        cellSize: MouseForwarding.CellSize? = nil,
        captureEnabled: Bool,
        mode: PaneMode,
        shiftHeld: Bool = false,
        lines: Int = 1
    ) -> MouseForwarding.Decision {
        MouseForwarding.decide(
            kind: kind, button: button, modifiers: modifiers,
            point: point, cellSize: cellSize ?? cell,
            captureEnabled: captureEnabled, mode: mode, shiftHeld: shiftHeld, lines: lines
        )
    }

    // MARK: - The truth table

    func testObserveModeAlwaysDrops() {
        for capture in [false, true] {
            for shift in [false, true] {
                XCTAssertEqual(
                    decide(captureEnabled: capture, mode: .observe, shiftHeld: shift), .drop,
                    "observe has no input path (capture=\(capture) shift=\(shift))")
            }
        }
    }

    func testControlCaptureOnNoShiftForwardsToApp() {
        for kind: MouseForwarding.EventKind in [.down, .up, .drag, .moved, .scrollUp, .scrollDown, .scrollLeft, .scrollRight] {
            let button: MouseForwarding.Button? = kind.wireRequiresButtonForTest ? .left : nil
            let decision = decide(kind: kind, button: button, captureEnabled: true, mode: .control)
            guard case .toApp = decision else {
                return XCTFail("control + capture + no shift must forward \(kind) to the app; got \(decision)")
            }
        }
    }

    func testShiftForcesSurfaceEvenUnderCapture() {
        XCTAssertEqual(
            decide(captureEnabled: true, mode: .control, shiftHeld: true), .toSurface,
            "Shift means libghostty selection, even when the app wants the mouse")
    }

    func testCaptureOffGoesToSurface() {
        for button: MouseForwarding.Button in [.left, .middle, .right] {
            XCTAssertEqual(
                decide(button: button, captureEnabled: false, mode: .control), .toSurface,
                "capture off is today's behavior: libghostty owns the click")
        }
        XCTAssertEqual(
            decide(kind: .scrollUp, button: nil, captureEnabled: false, mode: .control), .toSurface,
            "wheel with capture off stays local scrollback")
    }

    func testMissingCellSizeFallsBackToSurface() {
        let decision = MouseForwarding.decide(
            kind: .down, button: .left, modifiers: 0,
            point: .init(x: 10, y: 10), cellSize: nil,
            captureEnabled: true, mode: .control, shiftHeld: false, lines: 1
        )
        XCTAssertEqual(decision, .toSurface, "no cell size yet: never fabricate a cell, fall back to the surface")
    }

    func testButtonlessKindWithNoCellAlsoFallsBack() {
        let decision = MouseForwarding.decide(
            kind: .moved, button: nil, modifiers: 0,
            point: .init(x: 10, y: 10), cellSize: nil,
            captureEnabled: true, mode: .control, shiftHeld: false, lines: 1
        )
        XCTAssertEqual(decision, .toSurface)
    }

    // MARK: - Command shape and coordinate conversion

    /// Cells are ZERO-based on the wire. Point (75, 70) with an 8x16 cell is
    /// column floor(75/8)=9, row floor(70/16)=4 -- which herdr encodes as the
    /// 1-based SGR report ESC[<0;10;5M (confirmed live against this branch;
    /// see MouseForwarding.Command's doc and src/pane/input.rs:99).
    func testDownCommandConvertsPointToZeroBasedCell() {
        guard case .toApp(let command) = decide(
            point: .init(x: 75, y: 70), captureEnabled: true, mode: .control
        ) else {
            return XCTFail("expected toApp")
        }
        XCTAssertEqual(command.kind, "down")
        XCTAssertEqual(command.button, "left")
        XCTAssertEqual(command.column, 9)
        XCTAssertEqual(command.row, 4)
        XCTAssertEqual(command.lines, 1)
    }

    func testCellFloorsWithinACellAndClampsNegatives() {
        // Anywhere inside cell (0,0) -> column 0, row 0.
        guard case .toApp(let inside) = decide(point: .init(x: 7.9, y: 15.9), captureEnabled: true, mode: .control) else {
            return XCTFail("expected toApp")
        }
        XCTAssertEqual([inside.column, inside.row], [0, 0])
        // A point above/left of the surface (the AppKit exit sentinel is
        // negative) clamps to 0 rather than going negative.
        guard case .toApp(let outside) = decide(point: .init(x: -5, y: -5), captureEnabled: true, mode: .control) else {
            return XCTFail("expected toApp")
        }
        XCTAssertEqual([outside.column, outside.row], [0, 0])
    }

    func testModifiersAreCrosstermBits() {
        // shift(1) + control(2) + option(4) + command(8) = 15
        let bits = MouseForwarding.crosstermModifiers(shift: true, control: true, option: true, command: true)
        XCTAssertEqual(bits, 0b0000_1111)
        XCTAssertEqual(MouseForwarding.crosstermModifiers(shift: false, control: true, option: false, command: false), 0b0000_0010)
    }

    func testScrollCommandCarriesKindAndLinesAndNoButton() {
        guard case .toApp(let command) = decide(
            kind: .scrollDown, button: nil, point: .init(x: 24, y: 32),
            captureEnabled: true, mode: .control, lines: 3
        ) else {
            return XCTFail("expected toApp")
        }
        XCTAssertEqual(command.kind, "scroll_down")
        XCTAssertNil(command.button)
        XCTAssertEqual(command.column, 3)
        XCTAssertEqual(command.row, 2)
        XCTAssertEqual(command.lines, 3)
    }

    func testCommandJsonIsTerminalMouseNamespaced() {
        let command = MouseForwarding.Command(
            kind: "down", button: "right", column: 5, row: 3, modifiers: 2, lines: 1)
        let json = command.json()
        XCTAssertEqual(json["type"] as? String, "terminal.mouse")
        XCTAssertEqual(json["kind"] as? String, "down")
        XCTAssertEqual(json["button"] as? String, "right")
        XCTAssertEqual(json["column"] as? Int, 5)
        XCTAssertEqual(json["row"] as? Int, 3)
        XCTAssertEqual(json["modifiers"] as? Int, 2)
        XCTAssertEqual(json["lines"] as? Int, 1)
    }

    /// A button past middle (AppKit back/forward) has no `ClientMouseButton`
    /// wire variant, so it can never forward to the app even under capture --
    /// it falls back to the surface, where libghostty encodes it if reporting.
    func testOtherButtonHasNoWireFormAndFallsBackToSurface() {
        XCTAssertEqual(
            decide(button: .other(3), captureEnabled: true, mode: .control), .toSurface)
        XCTAssertNil(MouseForwarding.command(
            kind: .down, button: .other(3), modifiers: 0,
            point: .init(x: 0, y: 0), cellSize: cell, lines: 1))
    }

    func testDownKindWithNoButtonProducesNoCommand() {
        XCTAssertNil(MouseForwarding.command(
            kind: .down, button: nil, modifiers: 0,
            point: .init(x: 0, y: 0), cellSize: cell, lines: 1))
    }
}

private extension MouseForwarding.EventKind {
    var wireRequiresButtonForTest: Bool {
        switch self {
        case .down, .up, .drag: return true
        default: return false
        }
    }
}
