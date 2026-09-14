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
        paneIsFocused: Bool,
        shiftHeld: Bool = false,
        lines: Int = 1
    ) -> MouseForwarding.Decision {
        MouseForwarding.decide(
            kind: kind, button: button, modifiers: modifiers,
            point: point, cellSize: cellSize ?? cell, grid: nil,
            captureEnabled: captureEnabled, paneIsFocused: paneIsFocused, shiftHeld: shiftHeld, lines: lines
        )
    }

    // MARK: - The truth table

    /// An unfocused pane is attached like every other, but its mouse goes
    /// nowhere: its first primary click focuses it (the view's own
    /// `onPrimaryClick`), and nothing is forwarded.
    func testAnUnfocusedPaneAlwaysDrops() {
        for capture in [false, true] {
            for shift in [false, true] {
                XCTAssertEqual(
                    decide(captureEnabled: capture, paneIsFocused: false, shiftHeld: shift), .drop,
                    "an unfocused pane forwards nothing (capture=\(capture) shift=\(shift))")
            }
        }
    }

    func testControlCaptureOnNoShiftForwardsToApp() {
        for kind: MouseForwarding.EventKind in [.down, .up, .drag, .moved, .scrollUp, .scrollDown, .scrollLeft, .scrollRight] {
            let button: MouseForwarding.Button? = kind.wireRequiresButtonForTest ? .left : nil
            let decision = decide(kind: kind, button: button, captureEnabled: true, paneIsFocused: true)
            guard case .toApp = decision else {
                return XCTFail("control + capture + no shift must forward \(kind) to the app; got \(decision)")
            }
        }
    }

    func testShiftForcesSurfaceEvenUnderCapture() {
        XCTAssertEqual(
            decide(captureEnabled: true, paneIsFocused: true, shiftHeld: true), .toSurface,
            "Shift means libghostty selection, even when the app wants the mouse")
    }

    func testCaptureOffGoesToSurface() {
        for button: MouseForwarding.Button in [.left, .middle, .right] {
            XCTAssertEqual(
                decide(button: button, captureEnabled: false, paneIsFocused: true), .toSurface,
                "capture off is today's behavior: libghostty owns the click")
        }
    }

    // MARK: - wheel routes through herdr when the app has not claimed the mouse

    func testVerticalScrollWithCaptureOffRoutesToHerdrScroll() {
        XCTAssertEqual(
            decide(kind: .scrollUp, button: nil, captureEnabled: false, paneIsFocused: true, lines: 3),
            .toHerdrScroll(direction: .up, lines: 3),
            "wheel with capture off scrolls the real pane through herdr")
        XCTAssertEqual(
            decide(kind: .scrollDown, button: nil, captureEnabled: false, paneIsFocused: true, lines: 2),
            .toHerdrScroll(direction: .down, lines: 2))
    }

    /// herdr's `terminal.scroll` has no horizontal direction, so a horizontal
    /// wheel tick with capture off has nowhere to go.
    func testHorizontalScrollWithCaptureOffDrops() {
        XCTAssertEqual(decide(kind: .scrollLeft, button: nil, captureEnabled: false, paneIsFocused: true, lines: 3), .drop)
        XCTAssertEqual(decide(kind: .scrollRight, button: nil, captureEnabled: false, paneIsFocused: true, lines: 3), .drop)
    }

    /// A tick that crossed no whole cell (the accumulator's own zero-step
    /// case) must never send a herdr scroll command.
    func testZeroLinesScrollWithCaptureOffDrops() {
        XCTAssertEqual(decide(kind: .scrollUp, button: nil, captureEnabled: false, paneIsFocused: true, lines: 0), .drop)
    }

    /// Shift no longer has a special meaning for the wheel: capture off still
    /// routes to herdr even with Shift held.
    func testShiftHasNoEffectOnScrollDisposition() {
        XCTAssertEqual(
            decide(kind: .scrollUp, button: nil, captureEnabled: false, paneIsFocused: true, shiftHeld: true, lines: 4),
            .toHerdrScroll(direction: .up, lines: 4))
        guard case .toApp = decide(kind: .scrollUp, button: nil, captureEnabled: true, paneIsFocused: true, shiftHeld: true, lines: 1) else {
            return XCTFail("Shift must not force .toSurface for a scroll kind under capture")
        }
    }

    func testMissingCellSizeFallsBackToSurface() {
        let decision = MouseForwarding.decide(
            kind: .down, button: .left, modifiers: 0,
            point: .init(x: 10, y: 10), cellSize: nil, grid: nil,
            captureEnabled: true, paneIsFocused: true, shiftHeld: false, lines: 1
        )
        XCTAssertEqual(decision, .toSurface, "no cell size yet: never fabricate a cell, fall back to the surface")
    }

    func testButtonlessKindWithNoCellAlsoFallsBack() {
        let decision = MouseForwarding.decide(
            kind: .moved, button: nil, modifiers: 0,
            point: .init(x: 10, y: 10), cellSize: nil, grid: nil,
            captureEnabled: true, paneIsFocused: true, shiftHeld: false, lines: 1
        )
        XCTAssertEqual(decision, .toSurface)
    }

    // MARK: - Command shape and coordinate conversion

    /// Cells are ZERO-based on the wire. Point (75, 70) with an 8x16 cell is
    /// column floor(75/8)=9, row floor(70/16)=4, which herdr's encoder emits
    /// as the 1-based SGR report ESC[<0;10;5M (see MouseForwarding.Command).
    func testDownCommandConvertsPointToZeroBasedCell() {
        guard case .toApp(let command) = decide(
            point: .init(x: 75, y: 70), captureEnabled: true, paneIsFocused: true
        ) else {
            return XCTFail("expected toApp")
        }
        XCTAssertEqual(command.kind, "down")
        XCTAssertEqual(command.button, "left")
        XCTAssertEqual(command.column, 9)
        XCTAssertEqual(command.row, 4)
        XCTAssertEqual(command.lines, 1)
    }

    /// The far edge clamps to the last cell, as libghostty's own grid lookup
    /// does: herdr drops any event whose cell is outside the terminal, so a
    /// down in range whose up drifted into the right/bottom remainder would
    /// otherwise leave the app with an unpaired down.
    func testCellClampsToGridFarEdge() {
        let grid = MouseForwarding.GridSize(columns: 80, rows: 24)
        // 80 columns * 8pt = 640pt; the remainder past that and any overshoot
        // must land on column 79 / row 23.
        guard case .toApp(let command) = MouseForwarding.decide(
            kind: .up, button: .left, modifiers: 0,
            point: .init(x: 645, y: 400), cellSize: cell, grid: grid,
            captureEnabled: true, paneIsFocused: true, shiftHeld: false, lines: 1
        ) else {
            return XCTFail("expected toApp")
        }
        XCTAssertEqual(command.column, 79)
        XCTAssertEqual(command.row, 23)
        // Exactly on the last cell is unchanged by the clamp.
        guard case .toApp(let last) = MouseForwarding.decide(
            kind: .down, button: .left, modifiers: 0,
            point: .init(x: 639, y: 383), cellSize: cell, grid: grid,
            captureEnabled: true, paneIsFocused: true, shiftHeld: false, lines: 1
        ) else {
            return XCTFail("expected toApp")
        }
        XCTAssertEqual([last.column, last.row], [79, 23])
    }

    func testMissingGridDoesNotClamp() {
        // No grid known yet: the raw floor stands (herdr is the final gate).
        guard case .toApp(let command) = MouseForwarding.decide(
            kind: .down, button: .left, modifiers: 0,
            point: .init(x: 645, y: 400), cellSize: cell, grid: nil,
            captureEnabled: true, paneIsFocused: true, shiftHeld: false, lines: 1
        ) else {
            return XCTFail("expected toApp")
        }
        XCTAssertEqual([command.column, command.row], [80, 25])
    }

    func testCellFloorsWithinACellAndClampsNegatives() {
        // Anywhere inside cell (0,0) -> column 0, row 0.
        guard case .toApp(let inside) = decide(point: .init(x: 7.9, y: 15.9), captureEnabled: true, paneIsFocused: true) else {
            return XCTFail("expected toApp")
        }
        XCTAssertEqual([inside.column, inside.row], [0, 0])
        // A point above/left of the surface (the AppKit exit sentinel is
        // negative) clamps to 0 rather than going negative.
        guard case .toApp(let outside) = decide(point: .init(x: -5, y: -5), captureEnabled: true, paneIsFocused: true) else {
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
            captureEnabled: true, paneIsFocused: true, lines: 3
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
            decide(button: .other(3), captureEnabled: true, paneIsFocused: true), .toSurface)
        XCTAssertNil(MouseForwarding.command(
            kind: .down, button: .other(3), modifiers: 0,
            point: .init(x: 0, y: 0), cellSize: cell, grid: nil, lines: 1))
    }

    func testDownKindWithNoButtonProducesNoCommand() {
        XCTAssertNil(MouseForwarding.command(
            kind: .down, button: nil, modifiers: 0,
            point: .init(x: 0, y: 0), cellSize: cell, grid: nil, lines: 1))
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
