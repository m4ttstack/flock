import XCTest
@testable import FlockCore

@MainActor
final class CommandPaletteStateTests: XCTestCase {
    func testOpeningStartsEmptyOnTheFirstRow() {
        let state = CommandPaletteState()
        state.query = "old"
        state.open()
        XCTAssertTrue(state.isOpen)
        XCTAssertEqual(state.query, "")
        XCTAssertEqual(state.selection, 0)
        state.toggle()
        XCTAssertFalse(state.isOpen)
    }

    func testMovingStopsAtEitherEndAndDoesNotWrap() {
        let state = CommandPaletteState()
        state.open()
        state.move(-1, rowCount: 4)
        XCTAssertEqual(state.selection, 0)
        state.move(10, rowCount: 4)
        XCTAssertEqual(state.selection, 3)
    }

    func testTypingReturnsTheSelectionToTheTop() {
        let state = CommandPaletteState()
        state.open()
        state.move(2, rowCount: 4)
        state.query = "gl"
        XCTAssertEqual(state.selection, 0)
    }

    /// Rows can shrink under the selection while the palette is open.
    func testTheSelectionStaysInsideAShrinkingList() {
        let state = CommandPaletteState()
        state.open()
        state.move(5, rowCount: 6)
        state.clampSelection(rowCount: 2)
        XCTAssertEqual(state.selection, 1)
        XCTAssertEqual(state.selectedIndex(rowCount: 2), 1)
    }

    func testNoRowsMeansNothingSelected() {
        let state = CommandPaletteState()
        state.open()
        state.move(1, rowCount: 0)
        XCTAssertNil(state.selectedIndex(rowCount: 0))
    }

    func testTheKeysThePaletteTakes() {
        XCTAssertEqual(PaletteKey.decide(keyCode: 126, characters: nil, control: false, command: false), .up)
        XCTAssertEqual(PaletteKey.decide(keyCode: 125, characters: nil, control: false, command: false), .down)
        XCTAssertEqual(PaletteKey.decide(keyCode: 35, characters: "p", control: true, command: false), .up)
        XCTAssertEqual(PaletteKey.decide(keyCode: 45, characters: "n", control: true, command: false), .down)
        XCTAssertEqual(PaletteKey.decide(keyCode: 36, characters: "\r", control: false, command: false), .run)
        XCTAssertEqual(PaletteKey.decide(keyCode: 76, characters: "\u{3}", control: false, command: false), .run)
        XCTAssertEqual(PaletteKey.decide(keyCode: 53, characters: "\u{1b}", control: false, command: false), .close)
        XCTAssertEqual(PaletteKey.decide(keyCode: 0, characters: "a", control: false, command: false), .pass)
        XCTAssertEqual(PaletteKey.decide(keyCode: 35, characters: "p", control: false, command: true), .pass)
    }
}
